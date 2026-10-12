import "dart:async";
import "dart:io";

import "package:agent_chat/data/voice/file_voice_model_store.dart";
import "package:agent_chat/domain/voice_model.dart";
import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "fake_network.dart";
import "../harness.dart";

/// What is worth pinning is the shape of what lands on disk — the marker that
/// says a model is whole, and the nothing a cancelled download leaves behind.
/// The network itself is [FakeNetwork], so a suite run binds no port.
void main() {
  late Directory root;
  late FakeNetwork net;
  late FileVoiceModelStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("voice-models");
    net = FakeNetwork.inHalves({
      "/archive.tar.bz2": _archive(),
      "/model.onnx": List.filled(64, 7),
      "/tokens.txt": List.filled(64, 7),
    });
    store = FileVoiceModelStore(p.join(root.path, "models"), client: net);
  });

  tearDown(() async {
    net.hold?.complete();
    await root.delete(recursive: true);
  });

  String url(String path) => net.url(path);

  RecognitionModel plainModel({List<VoiceDownload>? downloads}) => RecognitionModel(
        id: "test-stt",
        name: "Test",
        engine: VoiceEngine.senseVoice,
        languages: "English",
        multilingual: false,
        model: "model.onnx",
        tokens: "tokens.txt",
        downloads: downloads ??
            [
              VoiceFile(url: url("/model.onnx"), bytes: 64),
              VoiceFile(url: url("/tokens.txt"), bytes: 64),
            ],
      );

  test("a finished download lands where the model says, and is marked whole", () async {
    final model = plainModel();
    final seen = await store.install(model).toList();

    expect(await store.installed(), {"test-stt"});
    final dir = await store.directoryOf(model);
    expect(dir, isNotNull);
    expect(File(p.join(dir!, "model.onnx")).existsSync(), isTrue);
    expect(File(p.join(dir, "tokens.txt")).existsSync(), isTrue);
    // Under stt/, not loose in the models directory.
    expect(p.split(dir), containsAllInOrder(["models", "stt", "test-stt"]));
    expect(seen.last.received, 128);
  });

  test("a cancelled download leaves nothing, installed or otherwise", () async {
    net.hold = Completer<void>();
    final model = plainModel();
    final sub = store.install(model).listen(null);
    // Under way mid-response: the first file's target exists, which the
    // progress stream never says at this size (it reports per megabyte).
    await waitFor(() => File(p.join(store.directoryFor(model), "model.onnx")).existsSync(),
        what: "the download to be under way");
    await sub.cancel();
    // Cancel's future is the teardown's: the half-written download went with
    // the cancellation, once the run had walked to its exit — the response
    // the cancel's close ended — and its discard had run. Nothing to poll.
    expect(Directory(store.directoryFor(model)).existsSync(), isFalse);

    expect(await store.installed(), isEmpty);
  });

  test("a model that will not download is not left half-installed", () async {
    final model = plainModel(downloads: [
      VoiceFile(url: url("/model.onnx"), bytes: 64),
      // Nothing answers for this one.
      VoiceFile(url: url("/gone.onnx"), bytes: 64),
    ]);

    await expectLater(store.install(model), emitsThrough(emitsError(isA<Object>())));
    expect(await store.installed(), isEmpty);
    expect(Directory(store.directoryFor(model)).existsSync(), isFalse);
  });

  test("an archive is unpacked with its top-level directory stripped", () async {
    final model = SpeechModel(
      id: "test-tts",
      name: "Test voice",
      engine: VoiceEngine.vits,
      languages: "English",
      multilingual: false,
      model: "model.onnx",
      tokens: "tokens.txt",
      dataDir: "espeak-ng-data",
      downloads: [VoiceArchive(url: url("/archive.tar.bz2"), bytes: 1)],
    );

    await store.install(model).drain<void>();

    final dir = await store.directoryOf(model);
    expect(dir, isNotNull);
    expect(File(p.join(dir!, "model.onnx")).readAsStringSync(), "weights");
    expect(File(p.join(dir, "espeak-ng-data", "phondata")).existsSync(), isTrue);
    // The archive itself is not left beside what came out of it.
    expect(File(p.join(dir, "_archive.tar.bz2")).existsSync(), isFalse);
    expect(p.split(dir), containsAllInOrder(["models", "tts", "test-tts"]));
  });

  test("deleting takes the directory and the marker with it", () async {
    final model = plainModel();
    await store.install(model).drain<void>();
    await store.delete(model);

    expect(await store.installed(), isEmpty);
    expect(await store.directoryOf(model), isNull);
  });

  test("installing over a half-finished attempt starts clean", () async {
    final model = plainModel();
    final leftover = Directory(store.directoryFor(model))..createSync(recursive: true);
    File(p.join(leftover.path, "junk.onnx")).writeAsStringSync("half a download");

    await store.install(model).drain<void>();

    expect(File(p.join(leftover.path, "junk.onnx")).existsSync(), isFalse);
    expect(await store.installed(), {"test-stt"});
  });
}

/// A `.tar.bz2` shaped like the ones sherpa-onnx publishes: one top-level
/// directory named after the model, with everything under it.
List<int> _archive() {
  final archive = Archive()
    ..add(ArchiveFile.string("some-voice-model/model.onnx", "weights"))
    ..add(ArchiveFile.string("some-voice-model/tokens.txt", "a b c"))
    ..add(ArchiveFile.string("some-voice-model/espeak-ng-data/phondata", "data"));
  return BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(archive));
}
