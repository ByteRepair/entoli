import "dart:io";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/local_instance.dart";
import "package:agent_chat/data/local/prompt_cache.dart";
import "package:flutter_test/flutter_test.dart";

import "../../fakes.dart";
import "../../harness.dart";

/// The prompt cache against a real directory and an instance that only
/// records what it was asked to save and restore — the two things it is made
/// of. What is worth pinning is the eviction order, since the file every chat
/// depends on is the one that is never written twice.
void main() {
  late FakeLocalRuntime runtime;
  late PromptCache cache;
  late LocalInstance model;

  // Three prompts, each the one before and a message more: the body every chat
  // shares, a turn of one chat, and the turn after it.
  const body = [LlmMessage(role: LlmRole.system, text: "s")];
  const turn = [...body, LlmMessage(role: LlmRole.user, text: "a")];
  const next = [...turn, LlmMessage(role: LlmRole.user, text: "b")];
  const other = [...body, LlmMessage(role: LlmRole.user, text: "z")];

  setUp(() {
    runtime = FakeLocalRuntime(restores: true);
    cache = PromptCache(tempDir().path);
    model = runtime.create(
      FakeLocalModelStore(installed: {"m"}).downloadedOfSync("m")!,
      const LocalLoad(contextLength: 8192, keepsPrompts: true),
      onChange: () {},
    );
  });

  PromptEntry entry(List<LlmMessage> messages, {int count = 10}) =>
      cache.lookup(model, testLocalOptions(keptPrompts: count), messages, [])!;

  /// The file the whole of [messages] is kept in.
  File fileOf(List<LlmMessage> messages) =>
      File(cache.fileOf(model, promptPrefixKeys(messages, []).first));

  /// A file already on disk, dated [daysAgo] so the eviction order is decided
  /// rather than left to the resolution of the filesystem's clock.
  File saved(List<LlmMessage> messages, {int daysAgo = 0}) {
    final file = fileOf(messages)..writeAsBytesSync(List.filled(16, 0));
    file.setLastModifiedSync(DateTime.now().subtract(Duration(days: daysAgo)));
    return file;
  }

  test("nothing is looked for with the cache off", () {
    expect(cache.lookup(model, testLocalOptions(), turn, []), isNull);
  });

  test("a restore is a use, so the file's date moves", () async {
    final file = saved(body, daysAgo: 30);
    final before = file.lastModifiedSync();

    expect(await entry(turn).warm(), isTrue);

    // Written once by the prefill and read by every chat after, so on write
    // order it is the oldest file within a chat or two and both bounds reap it
    // first. Read as a use, it is the newest.
    expect(runtime.restored, [file.path]);
    expect(file.lastModifiedSync().isAfter(before), isTrue);
  });

  test("a restore the instance refuses leaves the date alone", () async {
    runtime = FakeLocalRuntime();
    model = runtime.create(model.model, model.load, onChange: () {});
    final file = saved(body, daysAgo: 30);
    final before = file.lastModifiedSync();

    expect(await entry(turn).warm(), isFalse);

    expect(file.lastModifiedSync(), before);
  });

  test("nothing on disk is a miss, and asks the instance nothing", () async {
    expect(await entry(turn).warm(), isFalse);
    expect(runtime.restored, isEmpty);
  });

  test("what the instance already holds is not restored again", () async {
    saved(body);

    // A turn saves the whole prompt, so its instance holds it; the next turn
    // of the same chat is a continuation the live state serves.
    await entry(turn).keep();
    expect(await entry(next).warm(), isTrue);

    expect(runtime.restored, isEmpty);
  });

  test("an unchanged prompt is not saved twice", () async {
    await entry(turn).keep();
    await entry(turn).keep();

    expect(runtime.saved, [fileOf(turn).path]);
  });

  test("the body is kept under its own key", () async {
    await entry(turn).keepBody();

    expect(runtime.saved, [fileOf(body).path]);
  });

  test("saving evicts down to the count, oldest use first", () async {
    final old = saved(turn, daysAgo: 30);
    final recent = saved(other, daysAgo: 1);

    // The save is answered but writes no file — that is the runtime's job —
    // so the count is over the two files that were already there.
    await entry(next, count: 1).keep();

    // Eviction is deliberately un-awaited by `keep` — it must not gate a turn
    // behind a directory listing — so it is polled for, not slept on.
    await waitFor(() => !old.existsSync(), what: "the old file's eviction");

    expect(recent.existsSync(), isTrue);
  });

  test("what a runtime kept beside an evicted file goes with it", () async {
    final old = saved(turn, daysAgo: 30);
    final recent = saved(other, daysAgo: 1);
    final oldRecord = File("${old.path}.json")..writeAsStringSync("{}");
    final recentRecord = File("${recent.path}.json")..writeAsStringSync("{}");

    await entry(next, count: 1).keep();

    await waitFor(
      () => !oldRecord.existsSync(),
      what: "the old record's eviction",
    );
    expect(old.existsSync(), isFalse);
    expect(recentRecord.existsSync(), isTrue);
  });
}
