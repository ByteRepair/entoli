import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/reminder_alarms.dart";
import "package:agent_chat/domain/trigger.dart";
import "package:agent_chat/domain/trigger_runner.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";

import "../fakes.dart";

void main() {
  late Directory tmp;
  late AppConfig config;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("trigger_runner_test_");
    config = AppConfig.forDirectory(tmp.path, fileSystemIo);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ChatRepository repo() => ChatRepository(FileChatStore(config),
      FakeBackend(), () => AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude"), config);

  /// The runner with its two callbacks and the fake driver captured, so a test
  /// can assert what it stamped, when it told the sidebar, and what it drove.
  (TriggerRunner, List<Trigger>, List<String>, FakeTriggerTurnDriver)
      runner(ChatRepository repository, {ReminderAlarms? alarms}) {
    final stamped = <Trigger>[];
    final listed = <String>[];
    final driver = FakeTriggerTurnDriver();
    return (
      TriggerRunner(
        repo: repository,
        driver: driver,
        alarms: alarms ?? const UnavailableReminderAlarms(),
        onListChanged: listed.add,
        onTriggerFired: (t) async => stamped.add(t),
      ),
      stamped,
      listed,
      driver,
    );
  }

  Trigger trigger({String? chatId, TriggerSource? source}) => Trigger(
        id: "r1",
        name: "Morning sweep",
        prompt: "Check the builds",
        source: source ??
            ScheduleSource(at: DateTime(2026, 8, 22, 9)),
        chatId: chatId,
      );

  test("runs the prompt in a new chat in the trigger's project", () async {
    final repository = repo();
    final (run, _, listed, driver) = runner(repository);
    final result = await run.run(trigger(), "", const []);

    final chat = await repository.openChat(result.chatId);
    expect(chat.state.title, "Morning sweep");
    expect(chat.state.project, isNull);
    expect(listed, [result.chatId]);
    expect(driver.calls.single.chatId, result.chatId);
    // No fire reason, no added line: the user set this prompt, and it sends
    // as written.
    expect(driver.calls.single.prompt, "Check the builds");
    expect(result.outcome, TriggerOutcome.done);
  });

  test("a named project is resolved against the ones that exist", () async {
    final repository = repo();
    await repository.createProject("work");
    final (run, _, _, _) = runner(repository);
    final result = await run.run(
        Trigger(
            id: "r1",
            name: "n",
            prompt: "p",
            source: ScheduleSource(at: DateTime.now()),
            project: "work"),
        "",
        const ["work"]);

    final chat = await repository.openChat(result.chatId);
    expect(chat.state.project, "work");
  });

  test("writes meta.json with headless, approveMode never, and the TTL", () async {
    final repository = repo();
    final (run, _, _, _) = runner(repository);
    final result = await run.run(
      Trigger(
        id: "r1",
        name: "n",
        prompt: "p",
        source: ScheduleSource(at: DateTime(2026, 8, 22, 9)),
        tempChatTtl: TempChatTtl.off,
      ),
      "",
      const [],
    );

    final meta =
        ChatMeta.parse(File(config.metaFile(result.chatId)).readAsStringSync());
    expect(meta.approveMode, ApproveMode.never);
    expect(meta.headless, true);
    expect(meta.tempChatTtl, TempChatTtl.off);
    expect(File(config.stateFile(result.chatId)).existsSync(), isTrue);
  });

  test("no TTL of its own leaves the chat's to inherit", () async {
    final repository = repo();
    final (run, _, _, _) = runner(repository);
    final result = await run.run(trigger(), "", const []);

    final meta =
        ChatMeta.parse(File(config.metaFile(result.chatId)).readAsStringSync());
    expect(meta.tempChatTtl, isNull);
  });

  test("stamps fired before the turn runs", () async {
    final repository = repo();
    final stamped = <Trigger>[];
    final driver = FakeTriggerTurnDriver();

    final run = TriggerRunner(
      repo: repository,
      driver: driver,
      alarms: const UnavailableReminderAlarms(),
      onListChanged: (_) {},
      onTriggerFired: (t) async => stamped.add(t),
    );
    await run.run(trigger(), "", const []);

    // onTriggerFired is awaited before driver.send, so the stamp is in place
    // before the turn starts — a crash mid-turn must not re-run the prompt.
    expect(stamped.map((t) => t.id), ["r1"]);
    expect(stamped.single.lastFiredAt, isNotNull);
    expect(driver.calls, isNotEmpty);
  });

  test("returns the driver's outcome and snippet", () async {
    final repository = repo();
    final (run, _, _, driver) = runner(repository);
    driver.outcome = TriggerOutcome.error;
    driver.snippet = "partial reply";
    final result = await run.run(trigger(), "", const []);

    expect(result.outcome, TriggerOutcome.error);
    expect(result.snippet, "partial reply");
  });

  group("a trigger pointed at its own chat", () {
    test("sends into the chat rather than making one, not headless", () async {
      final repository = repo();
      final chat = await repository.createChat(title: "workshop");
      final (run, stamped, listed, driver) = runner(repository);
      final result = await run.run(trigger(chatId: chat.state.id), "", const []);

      expect(result.chatId, chat.state.id);
      expect(driver.calls.single.chatId, chat.state.id);
      // Not headless there: the created-chat flow wrote the trigger's meta;
      // the existing chat keeps its own, and a trigger turn has an ask_user
      // owner.
      final meta = await repository.loadMeta(chat.state.id);
      expect(meta.approveMode, isNot(ApproveMode.never));
      // No sidebar entry to make: the chat exists already.
      expect(listed, isEmpty);
      // The stamp still came first.
      expect(stamped.single.lastFiredAt, isNotNull);
    });

    test("words the reason into the prompt", () async {
      final repository = repo();
      final chat = await repository.createChat(title: "workshop");
      final (run, _, _, driver) = runner(repository);
      await run.run(trigger(chatId: chat.state.id), "file build.log changed", const []);

      expect(driver.calls.single.prompt,
          "Check the builds\n\n(file build.log changed)");
    });

    test("a chat that has been deleted disarms the trigger", () async {
      final repository = repo();
      final chat = await repository.createChat(title: "brief");
      final chatId = chat.state.id;
      await repository.deleteChat(chatId);
      final alarms = FakeReminderAlarms();
      final (run, stamped, _, driver) = runner(repository, alarms: alarms);
      final result = await run.run(trigger(chatId: chatId), "", const []);

      expect(driver.calls, isEmpty);
      expect(result.outcome, TriggerOutcome.error);
      // The trigger is disabled and disarmed, never re-pointed.
      expect(stamped.single.enabled, isFalse);
      expect(stamped.single.nextFireAt, isNull);
      expect(alarms.posted.single.body, contains("no longer exists"));
    });
  });
}