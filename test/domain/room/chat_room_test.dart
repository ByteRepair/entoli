import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart"
    show CallEvents, JobEnd, MessageRole, Retraction, jobEndedEvent;
import "package:agent_chat/domain/reaction.dart";
import "package:agent_chat/domain/shell_job.dart";
import "package:agent_chat/domain/project_settings.dart" show OmadaOrdering;
import "package:agent_chat/domain/room/chat_room.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/domain/room/roster.dart";

import "../../fakes.dart";
import "../../harness.dart";

/// A host with no Riverpod behind it: the settings are fields, and what the
/// room tells it is kept.
class _Host implements RoomHost {
  final states = <ChatViewState>[];
  final said = <String>[];
  final ended = <TurnEnd?>[];
  var settled = 0;

  @override
  Roster roster(String? project) =>
      Roster(omada: false, library: testLibrary());

  @override
  OmadaOrdering ordering(String? project) => OmadaOrdering.relay;

  @override
  int maxGenerations(String? project) => 10;

  @override
  int get turnRetries => 0;

  @override
  void stateChanged(ChatViewState state) => states.add(state);

  @override
  void firstSaid(String text) => said.add(text);

  @override
  Future<void> turnEnded(TurnEnd? reason, String errorLine) async =>
      ended.add(reason);

  @override
  void settledDone() => settled++;
}

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<(ChatRoom, _Host)> openRoom() async {
    final chat = await app.repo.createChat();
    final host = _Host();
    return (ChatRoom(chat.state.id, app.repo, host), host);
  }

  test("a send runs a turn and tells the host each step", () async {
    app.backend.scriptedEvents = const [TextDelta("hi"), DoneEvent()];
    final (room, host) = await openRoom();
    await room.send("hello");
    // `turnDone` completes before the room settles; the settle is the host's
    // last word.
    await waitFor(() => host.settled == 1, what: "the settle");

    expect(host.said, ["hello"]);
    expect(host.ended, [TurnEnd.done]);
    expect(host.settled, 1);
    expect(host.states.last, same(room.state));
    expect(room.state.isRunning, isFalse);
    expect(room.replyText, "hi");
  });

  test("a reaction to any message is said, and answered", () async {
    app.backend.scriptedEvents = const [TextDelta("hi"), DoneEvent()];
    final (room, host) = await openRoom();
    await room.send("hello");
    await waitFor(() => host.settled == 1, what: "the first settle");

    // The user's own message, which the main agent answers.
    final own = room.state.chat!.messages.first;
    await room.react(own.id, Reaction.thinking);
    await waitFor(() => host.settled == 2, what: "the reaction's settle");

    final messages = room.state.chat!.messages;
    expect(messages, hasLength(4));
    expect(messages[2].role, MessageRole.user);
    expect(messages[2].reaction?.messageId, own.id);
    expect(messages[2].reaction?.emoji, "🤔");
    expect(messages[3].role, MessageRole.assistant);
    // The log reads back the same.
    final reloaded = await app.repo.openChat(room.chatId);
    expect(reloaded.messages[2].reaction?.excerpt, "hello");
  });

  test("taking back a reaction whose turn runs lets that turn finish, and "
      "the log keeps the reaction, retracted", () async {
    app.backend.scriptedEvents = const [TextDelta("hi"), DoneEvent()];
    final (room, host) = await openRoom();
    await room.send("hello");
    await waitFor(() => host.settled == 1, what: "the first settle");

    final hold = app.backend.hold = Completer<void>();
    final own = room.state.chat!.messages.first;
    await room.react(own.id, Reaction.fire);
    await waitFor(() => room.state.isRunning, what: "the reaction's turn");
    // Reacting with what it already has takes it back.
    await room.react(own.id, Reaction.fire);
    expect(room.state.isRunning, isTrue);
    hold.complete();
    await waitFor(() => host.settled == 2, what: "the reaction's settle");

    expect(host.ended.last, TurnEnd.done);
    expect(room.state.chat!.messages, hasLength(4));
    expect(room.state.chat!.messages[2].retraction, Retraction.afterItsTurn);
    final reloaded = await app.repo.openChat(room.chatId);
    expect(reloaded.messages[2].retraction, Retraction.afterItsTurn);
    expect(reactionsOn(reloaded.messages), isEmpty);
  });

  test("a reaction taken back before its turn runs never runs", () async {
    app.backend.scriptedEvents = const [TextDelta("hi"), DoneEvent()];
    final hold = app.backend.hold = Completer<void>();
    final (room, host) = await openRoom();
    await room.send("hello");
    final own = room.state.chat!.messages.first;
    // The room is busy, so the reaction waits its turn.
    await room.react(own.id, Reaction.thumbsUp);
    await room.react(own.id, Reaction.thumbsUp);
    app.backend.hold = null;
    hold.complete();
    await waitFor(() => host.settled == 1, what: "the settle");
    await Future<void>.delayed(Duration.zero);

    expect(app.backend.prompts, hasLength(1));
    expect(room.state.isRunning, isFalse);
    final reloaded = await app.repo.openChat(room.chatId);
    expect(reloaded.messages.last.retraction, Retraction.beforeItsTurn);
  });

  test("a disposed room tells the host nothing more", () async {
    final hold = app.backend.hold = Completer<void>();
    final (room, host) = await openRoom();
    await room.send("hello");
    room.dispose();
    final seen = host.states.length;
    hold.complete();
    await Future<void>.delayed(Duration.zero);

    expect(host.states, hasLength(seen));
    expect(host.ended, isEmpty);
  });

  test("reset forgets the chat", () async {
    final (room, host) = await openRoom();
    await room.send("hello");
    await room.turnDone;
    room.reset();

    expect(room.state.chat, isNull);
    expect(host.states.last.chat, isNull);
  });

  test(
    "a job that ends between turns is written to the log and the chat",
    () async {
      final (room, host) = await openRoom();
      await room.send("hello");
      await room.turnDone;
      const end = JobEnd(jobId: 1, exitCode: 0, tail: "done");
      app.backend.jobsOf(room.chatId).endings.add((callId: "c1", end: end));
      await waitFor(
        () => room.state.chat?.jobEndOf("c1") != null,
        what: "the end on the chat",
      );

      expect(host.states.last.jobOf("c1"), const JobEnded(end));
      // The state changes before the append lands, which is real I/O.
      await waitFor(
        () async =>
            (await app.repo.readRecords(room.chatId)).last is CallEventRecord,
        what: "the end in the log",
      );
      final records = await app.repo.readRecords(room.chatId);
      expect(
        records.last,
        ChatRecord.callEvent(
          callId: "c1",
          kind: jobEndedEvent,
          data: end.toJson(),
        ),
      );
    },
  );

  test("a job goes from running to ended with no step between, the end "
      "landing before the backend drops it", () async {
    final (room, host) = await openRoom();
    await waitFor(() => room.state.chat != null, what: "the room's load");
    final jobs = app.backend.jobsOf(room.chatId);
    const job = ShellJob(id: 1, callId: "c1", command: "serve", logPath: "/l");
    jobs.jobs.value = [job];
    expect(room.state.jobOf("c1"), const JobRunning(job));

    const end = JobEnd(jobId: 1, exitCode: 0, tail: "");
    jobs.endings.add((callId: "c1", end: end));
    jobs.jobs.value = const [];
    expect(room.state.jobOf("c1"), const JobEnded(end));
    expect(room.state.runningJobs, isEmpty);
    expect(host.states.last.jobOf("c1"), const JobEnded(end));
  });
}
