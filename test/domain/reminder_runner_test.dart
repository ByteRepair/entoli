import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/reminder.dart";
import "package:agent_chat/domain/reminder_runner.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";

import "../fakes.dart";

void main() {
  late Directory tmp;
  late AppConfig config;
  late FakeBackend backend;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("reminder_runner_test_");
    config = AppConfig.forDirectory(tmp.path, fileSystemIo);
    backend = FakeBackend();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ChatRepository repo() => ChatRepository(FileChatStore(config), backend,
      () => AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude"), config);

  /// The runner with its two callbacks captured, so a test can assert what it
  /// stamped and when it told the sidebar.
  (ReminderRunner, List<Reminder>, List<String>) runner(ChatRepository repository) {
    final stamped = <Reminder>[];
    final listed = <String>[];
    return (
      ReminderRunner(
        repo: repository,
        onListChanged: listed.add,
        onReminderFired: (r) async => stamped.add(r),
      ),
      stamped,
      listed,
    );
  }

  test("runs the prompt in a new chat in the reminder's project", () async {
    final repository = repo();
    final (run, _, listed) = runner(repository);
    final result = await run.run(
      Reminder(
        id: "r1",
        name: "Morning sweep",
        prompt: "Check the builds",
        at: DateTime(2026, 8, 22, 9),
      ),
      const [],
    );

    // Named after the reminder, in the default project, and announced to the
    // sidebar — which is the only way a headless chat becomes visible.
    final chat = await repository.openChat(result.chatId);
    expect(chat.state.title, "Morning sweep");
    expect(chat.state.project, isNull);
    expect(listed, [result.chatId]);
    expect(backend.prompts.single.prompt.plainText, "Check the builds");
    expect(result.outcome, ReminderOutcome.done);
  });

  test("a named project is resolved against the ones that exist", () async {
    final repository = repo();
    await repository.createProject("work");
    final (run, _, _) = runner(repository);
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

  test("pins approveMode never and turns off ask_user for a headless turn", () async {
    final repository = repo();
    final (run, _, _) = runner(repository);
    await run.run(Reminder(id: "r1", name: "n", prompt: "p", at: DateTime.now()), const []);

    final settings = backend.prompts.single.settings;
    // A turn nobody watches must never park on an approval or a question:
    // there is nobody to answer either, and nothing behind that wait but time.
    expect(settings.offerAsk, isFalse);
    expect(settings.offerTask, isFalse);
  });

  test("writes meta.json with the pins; not temporary means permanent", () async {
    final repository = repo();
    final (run, _, _) = runner(repository);
    final result = await run.run(
      Reminder(id: "r1", name: "n", prompt: "p", at: DateTime.now(), temporary: false),
      const [],
    );

    final meta =
        ChatMeta.parse(File(config.metaFile(result.chatId)).readAsStringSync());
    expect(meta.approveMode, ApproveMode.never);
    expect(meta.tempChatTtl, TempChatTtl.off);
    expect(File(config.stateFile(result.chatId)).existsSync(), isTrue);
  });

  test("temporary leaves the TTL to inherit", () async {
    final repository = repo();
    final (run, _, _) = runner(repository);
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
    backend.hold = Completer<void>();
    addTearDown(() {
      if (!(backend.hold?.isCompleted ?? true)) backend.hold!.complete();
      backend.hold = null;
    });

    final run = ReminderRunner(
      repo: repository,
      onListChanged: (_) {},
      onReminderFired: (r) async {
        stamped.add(r);
        stampedDone.complete();
      },
    );
    final done =
        run.run(Reminder(id: "r1", name: "n", prompt: "p", at: DateTime.now()), const []);
    await stampedDone.future.timeout(const Duration(seconds: 5));
    // Before the turn finished: a crash here must not re-run the prompt.
    expect(stamped.map((r) => r.id), ["r1"]);
    expect(stamped.single.lastFiredAt, isNotNull);
    if (!backend.hold!.isCompleted) backend.hold!.complete();
    await done;
  });

  test("the log reads as a finished turn: opening records and a turnEnd", () async {
    backend.scriptedEvents = const [
      ResponseStart("resp-1"),
      TextDelta("All green."),
      DoneEvent(),
    ];
    final repository = repo();
    final (run, _, _) = runner(repository);
    final result =
        await run.run(Reminder(id: "r1", name: "n", prompt: "p", at: DateTime.now()), const []);

    final records =
        File(config.convFile(result.chatId)).readAsLinesSync().map(_decode).toList();
    expect(records.whereType<MessageRecord>().length, 2);
    expect(records.last, isA<TurnEndRecord>());
    expect((records.last as TurnEndRecord).reason, TurnEnd.done);
    expect(result.snippet, "All green.");
  });

  test("a failing turn still closes the log and reports error", () async {
    backend.scriptedEvents = const [ErrorEvent("provider down")];
    final repository = repo();
    final (run, _, _) = runner(repository);
    final result =
        await run.run(Reminder(id: "r1", name: "n", prompt: "p", at: DateTime.now()), const []);

    expect(result.outcome, ReminderOutcome.error);
    final records = File(config.convFile(result.chatId)).readAsLinesSync();
    expect(records.last.contains("turnEnd"), isTrue);
    expect(records.any((l) => l.contains("provider down")), isTrue);
    expect(result.snippet, isEmpty);
  });
}

/// One line of `conv.jsonl`. A broken line would be the one a kill landed in;
/// here every line is whole or the test has written something wrong.
ChatRecord _decode(String line) {
  final parsed = decodeLog("$line\n");
  return parsed.single;
}
