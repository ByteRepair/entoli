import "dart:io";

import "package:agent_chat/data/builtin/llm/local_kv_cache.dart";
import "package:agent_chat/data/local/file_kv_cache.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:flutter_test/flutter_test.dart";
import "../../harness.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:path/path.dart" as p;

/// The disk half of the KV cache, against a real directory and a stand-in for
/// llama.cpp's `/slots/0` — the two things it is made of. What is worth
/// pinning is the eviction order, since the dump every chat depends on is the
/// one that is never written twice.
void main() {
  late Directory dir;
  late LocalEndpoint at;

  /// The slot actions the cache asked for, in order.
  late List<String> actions;

  /// What the server answers with, so a build with no slot save/restore in it
  /// (501) can be told from one that has it.
  var status = 200;

  /// The cache under test. The client stands in for the running server, which
  /// is the only part of this that was ever a socket.
  FileKvCache cache() => FileKvCache(
    dir.path,
    client: MockClient((request) {
      actions.add(request.url.queryParameters["action"] ?? "");
      return Future.value(http.Response("", status));
    }),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp("kv_cache_test_");
    actions = [];
    status = 200;
    at = const LocalEndpoint(
      baseUrl: "http://127.0.0.1:8080/v1",
      apiKey: "k",
      contextLength: 8192,
    );
  });

  tearDown(() => dir.delete(recursive: true));

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

    expect(await cache().warm(at, namespace: "ns", keys: ["body"]), isTrue);

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

    expect(await cache().warm(at, namespace: "ns", keys: ["body"]), isFalse);

    expect(body.lastModifiedSync(), before);
  });

  test("nothing on disk is a miss, and asks the server nothing", () async {
    expect(await cache().warm(at, namespace: "ns", keys: ["gone"]), isFalse);
    expect(actions, isEmpty);
  });

  test("saving evicts down to the count, oldest use first", () async {
    dump("ns", "old", daysAgo: 30);
    dump("ns", "recent", daysAgo: 1);

    // The save is answered but writes no file — that is the real server's job —
    // so the count is over the two dumps that were already there.
    await cache().keep(at, namespace: "ns", key: "new", count: 1);

    // Eviction is deliberately un-awaited by `keep` — it must not gate a turn
    // behind a directory listing — so the eviction is polled until the oldest
    // dump is gone, not beaten at with a sleep.
    await waitFor(
      () => !File(p.join(dir.path, kvFilename("ns", "old"))).existsSync(),
      what: "the old dump's eviction",
    );

    expect(actions, ["save"]);
    expect(
      File(p.join(dir.path, kvFilename("ns", "recent"))).existsSync(),
      isTrue,
    );
  });
}
