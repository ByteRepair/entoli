import "dart:async";
import "dart:io";

import "package:agent_chat/data/local/file_local_model_store.dart";
import "package:agent_chat/domain/local_model.dart";
import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

/// Against a real socket, for the reason `file_rootfs_store_test.dart` is: what
/// is worth pinning is the shape of what lands on disk — the marker that says a
/// model is whole, and the nothing a cancelled or corrupted download leaves —
/// and a faked client would only ever prove the fake.
void main() {
  late Directory root;
  late HttpServer server;
  late List<int> weights;

  /// Blocks the response until it is completed, so a test can cancel mid-flight.
  Completer<void>? held;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("local-model-store");
    held = null;
    weights = List.generate(4096, (i) => i % 256);

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((request) async {
      final body = request.uri.path == "/rubbish" ? List.filled(64, 7) : weights;
      request.response.headers.contentType = ContentType.binary;
      request.response.add(body.sublist(0, body.length ~/ 2));
      await request.response.flush();
      if (held != null) await held!.future;
      request.response.add(body.sublist(body.length ~/ 2));
      await request.response.close();
    }));
  });

  tearDown(() async {
    held?.complete();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  String url(String path) => "http://${server.address.address}:${server.port}$path";

  LocalModel gguf({String path = "/model.gguf", String? sha}) => LocalModel(
        id: "test-model",
        name: "Test 1B",
        parameters: "1B",
        url: url(path),
        bytes: weights.length,
        sha256: sha ?? "${sha256.convert(weights)}",
        contextLength: 4096,
        kvBytesPerToken: 49152,
        licence: "Apache-2.0",
      );

  FileLocalModelStore store() => FileLocalModelStore(root.path);

  test("a finished download is the weights and a marker", () async {
    final model = gguf();

    await store().install(model).drain<void>();

    expect(await store().installed(), {"test-model"});
    final file = store().fileOfSync(model);
    expect(file, isNotNull);
    expect(File(file!).readAsBytesSync(), weights);
    // Written last, and the whole of what "installed" means.
    expect(File(p.join(root.path, "test-model", ".complete")).existsSync(), isTrue);
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

  test("cancelling leaves nothing behind", () async {
    held = Completer<void>();
    final subscription = store().install(gguf()).listen(null);
    // Far enough in for the first half to have landed on disk.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await subscription.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await store().installed(), isEmpty);
    expect(Directory(p.join(root.path, "test-model")).existsSync(), isFalse);
  });

  test("an unfinished directory is not installed", () async {
    // What a killed process leaves: the file, and no marker. Nothing may load
    // it, because half a GGUF is a server that exits on its first read.
    final dir = Directory(p.join(root.path, "test-model"))..createSync(recursive: true);
    File(p.join(dir.path, "model.gguf")).writeAsBytesSync(weights.sublist(0, 10));

    expect(await store().installed(), isEmpty);
    expect(store().fileOfSync(gguf()), isNull);
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

  /// `fileOfSync` is asked once per catalog entry every time the provider list
  /// is built, which is several times a turn — so it remembers what it found.
  /// One store across all three calls, deliberately: a fresh one per call would
  /// have an empty cache and prove nothing about the remembering.
  group("what it remembers about the marker", () {
    test("an install and a delete both reach it", () async {
      final one = store();

      expect(one.fileOfSync(gguf()), isNull);
      await one.install(gguf()).drain<void>();
      expect(one.fileOfSync(gguf()), isNotNull);
      await one.delete(gguf().id);

      // The hazard the cache introduces: a model deleted while the app runs,
      // still answered for out of what was remembered before it went.
      expect(one.fileOfSync(gguf()), isNull);
    });

    test("a download that was not kept is not remembered as installed",
        () async {
      final one = store();

      await one.install(gguf(sha: "not-the-checksum")).drain<void>().onError(
          (_, _) {});

      expect(one.fileOfSync(gguf()), isNull);
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
