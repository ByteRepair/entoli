import "dart:async";
import "dart:io";

import "package:agent_chat/data/local/file_local_model_store.dart";
import "package:agent_chat/data/local/model_format.dart";
import "package:agent_chat/domain/local_model.dart";
import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "../fake_network.dart";
import "../../harness.dart";
import "gguf_bytes.dart";

/// For the reason `file_rootfs_store_test.dart` is: what is worth pinning is
/// the shape of what lands on disk — the marker that says a model is whole,
/// the record that says what it is, and the nothing a cancelled or corrupted
/// download leaves. The network itself is [FakeNetwork], so a suite run binds
/// no port.
void main() {
  late Directory root;
  late FakeNetwork net;
  late List<int> weights;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("local-model-store");
    final header = tinyModel();
    weights = [...header, ...List.generate(4096 - header.length, (i) => i % 256)];
    net = FakeNetwork.inHalves({
      "/model.gguf": weights,
      "/rubbish": List.filled(64, 7),
    });
  });

  tearDown(() async {
    net.hold?.complete();
    await root.delete(recursive: true);
  });

  String url(String path) => net.url(path);

  LocalModel gguf({String path = "/model.gguf", String? sha, bool checked = true}) =>
      GgufModel(
        id: "test-model",
        name: "Test 1B",
        parameters: "1B",
        url: url(path),
        size: checked ? weights.length : null,
        sha256: checked ? sha ?? "${sha256.convert(weights)}" : null,
        licence: "Apache-2.0",
      );

  FileLocalModelStore store() =>
      FileLocalModelStore(root.path, format: const GgufFormat(), client: net);

  test("a finished download is the weights, its record and a marker", () async {
    await store().install(gguf()).drain<void>();

    expect(await store().installed(), {"test-model"});
    final model = store().downloadedOfSync("test-model")!;
    expect(File(model.file).readAsBytesSync(), weights);
    // What it was fetched as, and what its own header says.
    expect(model.name, "Test 1B");
    expect(model.licence, "Apache-2.0");
    expect(model.quantisation, "Q4_0");
    expect(model.contextLength, 32768);
    expect(model.kvBytesPerToken, 4 * 2 * 128 * 2);
    // Written last, and the whole of what "installed" means.
    expect(File(p.join(root.path, "test-model", ".complete")).existsSync(), isTrue);
  });

  test("a model of several files lands every one, on one bar", () async {
    final side = List.filled(64, 7);
    final model = _Files("test-model", [
      ModelFile(
          path: ggufWeights,
          url: url("/model.gguf"),
          bytes: weights.length,
          sha256: "${sha256.convert(weights)}"),
      ModelFile(
          path: "tokenizer/vocab.bin",
          url: url("/rubbish"),
          bytes: side.length,
          sha256: "${sha256.convert(side)}"),
    ]);

    final progress = await store().install(model).toList();

    final dir = p.join(root.path, "test-model");
    expect(File(p.join(dir, ggufWeights)).readAsBytesSync(), weights);
    expect(File(p.join(dir, "tokenizer", "vocab.bin")).readAsBytesSync(), side);
    // The second file's bar starts where the first's ended.
    expect(progress.every((each) => each.total == weights.length + side.length), isTrue);
    expect(progress.last.received, weights.length + side.length);
    expect(await store().installed(), {"test-model"});
  });

  test("a link with nothing checked is kept, named by its own file", () async {
    await store().install(gguf(checked: false)).drain<void>();

    expect(store().downloadedOfSync("test-model")?.bytes, weights.length);
  });

  test("a file that is no model is not kept, checked or not", () async {
    await expectLater(
      store().install(gguf(path: "/rubbish", checked: false)).drain<void>(),
      throwsA(isA<StateError>()),
    );

    expect(await store().installed(), isEmpty);
  });

  test("a model an older build downloaded is described from its header", () async {
    // Weights and a marker, and no record: what every build before records
    // left behind.
    final dir = Directory(p.join(root.path, "qwen3.5-2b-q4_0"))..createSync(recursive: true);
    File(p.join(dir.path, "model.gguf")).writeAsBytesSync(weights);
    File(p.join(dir.path, ".complete")).writeAsStringSync("");

    expect(await store().installed(), {"qwen3.5-2b-q4_0"});
    expect(store().downloadedOfSync("qwen3.5-2b-q4_0")?.name, "Tiny 1B");
    expect(File(p.join(dir.path, "model.json")).existsSync(), isTrue);
  });

  test("a file that is not what was checked is not kept", () async {
    // A gigabyte over somebody's mobile data, and the publisher already says
    // what it should come to.
    await expectLater(
      store().install(gguf(path: "/rubbish")).drain<void>(),
      throwsA(isA<StateError>()),
    );

    expect(await store().installed(), isEmpty);
    expect(Directory(p.join(root.path, "test-model")).existsSync(), isFalse);
  });

  // Once stalled past the 30-second default on a loaded CI runner, the same
  // commit green on the run beside it: runner load, not a race. Time to
  // settle, and the default for every other test stands.
  test("cancelling leaves nothing behind", () async {
    net.hold = Completer<void>();
    final subscription = store().install(gguf()).listen(null);
    // Under way mid-response: the target exists, which the progress stream
    // never says at this size (it reports per megabyte).
    await waitFor(() => File(p.join(root.path, "test-model", "model.gguf")).existsSync(),
        what: "the download to be under way");

    await subscription.cancel();
    // Cancel's future is the teardown's: the half-written download went
    // with the cancellation once its discard had run. Nothing to poll.
    expect(Directory(p.join(root.path, "test-model")).existsSync(), isFalse);

    expect(await store().installed(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test("an unfinished directory is not installed", () async {
    // What a killed process leaves: the file, and no marker. Nothing may load
    // it, because half a GGUF is a server that exits on its first read.
    final dir = Directory(p.join(root.path, "test-model"))..createSync(recursive: true);
    File(p.join(dir.path, "model.gguf")).writeAsBytesSync(weights.sublist(0, 10));

    expect(await store().installed(), isEmpty);
    expect(store().downloadedOfSync("test-model"), isNull);
  });

  test("installing again replaces what an earlier attempt left", () async {
    final dir = Directory(p.join(root.path, "test-model"))..createSync(recursive: true);
    File(p.join(dir.path, "model.gguf")).writeAsBytesSync(const [1, 2, 3]);

    await store().install(gguf()).drain<void>();

    expect(File(p.join(dir.path, "model.gguf")).readAsBytesSync(), weights);
  });

  test("deleting takes the whole directory", () async {
    await store().install(gguf()).drain<void>();

    await store().delete(gguf().id);

    expect(await store().installed(), isEmpty);
    expect(Directory(p.join(root.path, "test-model")).existsSync(), isFalse);
  });

  /// The list is asked every time the provider list is built, which is
  /// several times a turn — so it remembers what it found. One store across
  /// all three calls, deliberately: a fresh one per call would have an empty
  /// cache and prove nothing about the remembering.
  group("what it remembers about the disk", () {
    test("an install and a delete both reach it", () async {
      final one = store();

      expect(one.downloadedSync(), isEmpty);
      await one.install(gguf()).drain<void>();
      expect(one.downloadedOfSync("test-model"), isNotNull);
      await one.delete(gguf().id);

      // The hazard the cache introduces: a model deleted while the app runs,
      // still answered for out of what was remembered before it went.
      expect(one.downloadedSync(), isEmpty);
    });

    test("a download that was not kept is not remembered as installed",
        () async {
      final one = store();

      await one.install(gguf(sha: "not-the-checksum")).drain<void>().onError(
          (_, _) {});

      expect(one.downloadedSync(), isEmpty);
    });
  });

  test("progress is reported against the size the catalog says", () async {
    final seen = <int>[];

    await for (final progress in store().install(gguf())) {
      seen.add(progress.received);
      expect(progress.total, weights.length);
    }

    // The bar reads the total before the first byte arrives, so it starts at
    // zero and ends at the whole thing.
    expect(seen.first, 0);
    expect(seen.last, weights.length);
  });
}

class _Files extends LocalModel {
  const _Files(String id, this.files) : super(id: id, name: id);

  @override
  final List<ModelFile> files;

  @override
  String? get source => null;
}
