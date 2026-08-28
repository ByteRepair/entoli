import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/reminder.dart";
import "package:agent_chat/domain/reminder_runner.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";

import "../fakes.dart";

/// A driver that stamps a completer before returning, so a test can assert
/// the reminder was stamped before the turn would have run.
class _StampThenHangDriver implements ReminderTurnDriver {
  _StampThenHangDriver(this._inner, this.stampedDone);
  final ReminderTurnDriver _inner;
  final Completer<void> stampedDone;

  @override
  Future<({ReminderOutcome outcome, String snippet})> send(
      String chatId, String prompt) async {
    await stampedDone.future;
    return _inner.send(chatId, prompt);
  }
}

void main() {
  late Directory tmp;
  late AppConfig config;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("reminder_runner_test_");
    config = AppConfig.forDirectory(tmp.path, fileSystemIo);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ChatRepository repo() => ChatRepository(FileChatStore(config),
      FakeBackend(), () => AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude"), config);

  /// The runner with its two callbacks and the fake driver captured, so a test
  /// can assert what it stamped, when it told the sidebar, and what it drove.
  (ReminderRunner, List<Reminder>, List<String>, FakeReminderTurnDriver)
      runner(ChatRepository repository) {
    final stamped = <Reminder>[];
    final listed = <String>[];
    final driver = FakeReminderTurnDriver();
    return (
      ReminderRunner(
        repo: repository,
        driver: driver,
        onListChanged: listed.add,
        onReminderFired: (r) async => stamped.add(r),
      ),
      stamped,
      listed,
      driver,
    );
  }

  test("runs the prompt in a new chat in the reminder's project", () async {
    final repository = repo();
    final (run, _, listed, driver) = runner(repository);
    final result = await run.run(
      Reminder(
        id: "r1",
        name: "Morning sweep",
        prompt: "Check the builds",
        at: DateTime(2026, 8, 22, 9),
      ),
      const [],
    );

    final chat = await repository.openChat(result.chatId);
    expect(chat.state.title, "Morning sweep");
    expect(chat.state.project, isNull);
    expect(listed, [result.chatId]);
    expect(driver.calls.single.chatId, result.chatId);
    expect(driver.calls.single.prompt, "Check the builds");
    expect(result.outcome, ReminderOutcome.done);
  });

  test("a named project is resolved against the ones that exist", () async {
    final repository = repo();
    await repository.createProject("work");
    final (run, _, _, _) = runner(repository);
    final result = await run.run(
      Reminder(
          id: "r1",
          name: "n",
          prompt: "p",
          at: DateTime.now(),
          project: "work"),
      const ["work"],
    );

    final chat = await repository.openChat(result.chatId);
    expect(chat.state.project, "work");
  });

  test("writes meta.json with headless, approveMode never, and the TTL", () async {
    final repository = repo();
    final (run, _, _, _) = runner(repository);
    final result = await run.run(
      Reminder(
        id: "r1",
        name: "n",
        prompt: "p",
        at: DateTime.now(),
        tempChatTtl: TempChatTtl.off,
      ),
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
    final result = await run.run(
      Reminder(id: "r1", name: "n", prompt: "p", at: DateTime.now()),
      const [],
    );

    final meta =
        ChatMeta.parse(File(config.metaFile(result.chatId)).readAsStringSync());
    expect(meta.tempChatTtl, isNull);
  });

  test("stamps fired before the turn runs", () async {
    final repository = repo();
    final stamped = <Reminder>[];
    final stampedDone = Completer<void>();
    final driver = FakeReminderTurnDriver();

    final run = ReminderRunner(
      repo: repository,
      driver: _StampThenHangDriver(driver, stampedDone),
      onListChanged: (_) {},
      onReminderFired: (r) async {
        stamped.add(r);
        stampedDone.complete();
      },
    );
    final done =
        run.run(Reminder(id: "r1", name: "n", prompt: "p", at: DateTime.now()), const []);
    await stampedDone.future.timeout(const Duration(seconds: 5));
    expect(stamped.map((r) => r.id), ["r1"]);
    expect(stamped.single.lastFiredAt, isNotNull);
    await done;
  });

  test("returns the driver's outcome and snippet", () async {
    final repository = repo();
    final (run, _, _, driver) = runner(repository);
    driver.outcome = ReminderOutcome.error;
    driver.snippet = "partial reply";
    final result = await run.run(
      Reminder(id: "r1", name: "n", prompt: "p", at: DateTime.now()),
      const [],
    );

    expect(result.outcome, ReminderOutcome.error);
    expect(result.snippet, "partial reply");
  });
}