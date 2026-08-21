import "dart:async";
import "dart:io";

import "package:agent_chat/data/builtin/llm/local_kv_cache.dart";
import "package:agent_chat/data/local/file_kv_cache.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

/// The disk half of the KV cache, against a real directory and a real server
/// answering `/slots/0` — the two things it is made of. What is worth pinning
/// is the eviction order, since the dump every chat depends on is the one that
/// is never written twice.
void main() {
  late Directory dir;
  late HttpServer server;
  late LocalEndpoint at;

  /// The slot actions the cache asked for, in order.
  late List<String> actions;

  /// What the server answers with, so a build with no slot save/restore in it
  /// (501) can be told from one that has it.
  var status = 200;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp("kv_cache_test_");
    actions = [];
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((request) async {
      actions.add(request.uri.queryParameters["action"] ?? "");
      await request.drain<void>();
      request.response.statusCode = status;
      await request.response.close();
    }));
    at = LocalEndpoint(
      baseUrl: "http://127.0.0.1:${server.port}/v1",
      apiKey: "k",
      contextLength: 8192,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  /// A dump already on disk, dated [daysAgo] so the eviction order is decided
  /// rather than left to the resolution of the filesystem's clock.
  File dump(String namespace, String key, {int daysAgo = 0}) {
    final file = File(p.join(dir.path, kvFilename(namespace, key)))
      ..writeAsBytesSync(List.filled(16, 0));
    file.setLastModifiedSync(DateTime.now().subtract(Duration(days: daysAgo)));
    return file;
  }

  test("a restore is a use, so the dump's date moves", () async {
    final body = dump("ns", "body", daysAgo: 30);
    final before = body.lastModifiedSync();

    expect(await FileKvCache(dir.path).warm(at, namespace: "ns", keys: ["body"]),
        isTrue);

    // The whole of what replaced exempting this file from eviction by name: it
    // is written once by the prefill and read by every chat after, so on write
    // order it is the oldest file in the directory within a chat or two and
    // both bounds reap it first. Read as a use, it is the newest.
    expect(actions, ["restore"]);
    expect(body.lastModifiedSync().isAfter(before), isTrue);
  });

  test("a restore that the server refuses leaves the date alone", () async {
    status = 501;
    final body = dump("ns", "body", daysAgo: 30);
    final before = body.lastModifiedSync();

    expect(await FileKvCache(dir.path).warm(at, namespace: "ns", keys: ["body"]),
        isFalse);

    expect(body.lastModifiedSync(), before);
  });

  test("nothing on disk is a miss, and asks the server nothing", () async {
    expect(await FileKvCache(dir.path).warm(at, namespace: "ns", keys: ["gone"]),
        isFalse);
    expect(actions, isEmpty);
  });

  test("saving evicts down to the count, oldest use first", () async {
    dump("ns", "old", daysAgo: 30);
    dump("ns", "recent", daysAgo: 1);

    // The save is answered but writes no file — that is the real server's job —
    // so the count is over the two dumps that were already there.
    await FileKvCache(dir.path)
        .keep(at, namespace: "ns", key: "new", count: 1);
    await _settle();

    expect(actions, ["save"]);
    expect(File(p.join(dir.path, kvFilename("ns", "old"))).existsSync(), isFalse);
    expect(
        File(p.join(dir.path, kvFilename("ns", "recent"))).existsSync(), isTrue);
  });
}

/// Eviction is deliberately not awaited by `keep` — it must not gate a turn
/// behind a directory listing — so a test that asserts on it waits for it.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));
