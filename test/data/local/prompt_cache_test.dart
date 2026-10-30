import "dart:io";

import "package:agent_chat/data/local/local_instance.dart";
import "package:agent_chat/data/local/prompt_cache.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "../../fakes.dart";
import "../../harness.dart";

/// The prompt cache against a real directory and an instance that only
/// records what it was asked to save and restore — the two things it is made
/// of. What is worth pinning is the eviction order, since the file every chat
/// depends on is the one that is never written twice.
void main() {
  late Directory dir;
  late FakeLocalRuntime runtime;

  setUp(() {
    dir = tempDir();
    runtime = FakeLocalRuntime(restores: true);
  });

  LocalInstance instance() => runtime.create(
    FakeLocalModelStore(installed: {"m"}).downloadedOfSync("m")!,
    const LocalLoad(contextLength: 8192, keepsPrompts: true),
    onChange: () {},
  );

  /// A file already on disk, dated [daysAgo] so the eviction order is decided
  /// rather than left to the resolution of the filesystem's clock.
  File saved(String namespace, String key, {int daysAgo = 0}) {
    final file = File(p.join(dir.path, promptFilename(namespace, key)))
      ..writeAsBytesSync(List.filled(16, 0));
    file.setLastModifiedSync(DateTime.now().subtract(Duration(days: daysAgo)));
    return file;
  }

  test("a restore is a use, so the file's date moves", () async {
    final body = saved("ns", "body", daysAgo: 30);
    final before = body.lastModifiedSync();

    final cache = PromptCache(dir.path);
    expect(
      await cache.warm(instance(), namespace: "ns", keys: ["body"]),
      isTrue,
    );

    // Written once by the prefill and read by every chat after, so on write
    // order it is the oldest file within a chat or two and both bounds reap it
    // first. Read as a use, it is the newest.
    expect(runtime.restored, [promptFilename("ns", "body")]);
    expect(body.lastModifiedSync().isAfter(before), isTrue);
  });

  test("a restore the instance refuses leaves the date alone", () async {
    runtime = FakeLocalRuntime();
    final body = saved("ns", "body", daysAgo: 30);
    final before = body.lastModifiedSync();

    final cache = PromptCache(dir.path);
    expect(
      await cache.warm(instance(), namespace: "ns", keys: ["body"]),
      isFalse,
    );

    expect(body.lastModifiedSync(), before);
  });

  test("nothing on disk is a miss, and asks the instance nothing", () async {
    final cache = PromptCache(dir.path);
    expect(
      await cache.warm(instance(), namespace: "ns", keys: ["gone"]),
      isFalse,
    );
    expect(runtime.restored, isEmpty);
  });

  test("what the instance already holds is not restored again", () async {
    saved("ns", "body");
    final cache = PromptCache(dir.path);
    final model = instance();

    // A turn saves the whole prompt, so its instance holds it; the next turn
    // of the same chat is a continuation the live state serves.
    await cache.keep(model, namespace: "ns", key: "turn", count: 10);
    expect(
      await cache.warm(model, namespace: "ns", keys: ["next", "turn", "body"]),
      isTrue,
    );

    expect(runtime.restored, isEmpty);
  });

  test("an unchanged prompt is not saved twice", () async {
    final cache = PromptCache(dir.path);
    final model = instance();

    await cache.keep(model, namespace: "ns", key: "turn", count: 10);
    await cache.keep(model, namespace: "ns", key: "turn", count: 10);

    expect(runtime.saved, [promptFilename("ns", "turn")]);
  });

  test("saving evicts down to the count, oldest use first", () async {
    saved("ns", "old", daysAgo: 30);
    saved("ns", "recent", daysAgo: 1);

    // The save is answered but writes no file — that is the runtime's job —
    // so the count is over the two files that were already there.
    await PromptCache(
      dir.path,
    ).keep(instance(), namespace: "ns", key: "new", count: 1);

    // Eviction is deliberately un-awaited by `keep` — it must not gate a turn
    // behind a directory listing — so it is polled for, not slept on.
    await waitFor(
      () => !File(p.join(dir.path, promptFilename("ns", "old"))).existsSync(),
      what: "the old file's eviction",
    );

    expect(
      File(p.join(dir.path, promptFilename("ns", "recent"))).existsSync(),
      isTrue,
    );
  });
}
