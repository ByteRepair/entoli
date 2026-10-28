import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart" show CallEvents, JobEnd, jobEndedEvent;
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

  test("a job that ends between turns is written to the log and the chat",
      () async {
    final (room, host) = await openRoom();
    await room.send("hello");
    await room.turnDone;
    const end = JobEnd(jobId: 1, exitCode: 0, tail: "done");
    app.backend.jobsOf(room.chatId).endings.add((callId: "c1", end: end));
    await waitFor(() => room.state.chat?.jobEndOf("c1") != null,
        what: "the end on the chat");

    expect(host.states.last.jobOf("c1"), const JobEnded(end));
    final records = await app.repo.readRecords(room.chatId);
    expect(records.last,
        ChatRecord.callEvent(callId: "c1", kind: jobEndedEvent, data: end.toJson()));
  });

  test("a job is running from when it starts until its end lands, even past "
      "leaving the backend's list", () async {
    final (room, host) = await openRoom();
    final jobs = app.backend.jobsOf(room.chatId);
    const job = ShellJob(id: 1, callId: "c1", command: "serve", logPath: "/l");
    jobs.jobs.value = [job];
    expect(room.state.jobOf("c1"), const JobRunning(job));

    jobs.jobs.value = const [];
    expect(room.state.jobOf("c1"), const JobRunning(job));

    const end = JobEnd(jobId: 1, exitCode: 0, tail: "");
    jobs.endings.add((callId: "c1", end: end));
    await waitFor(() => room.state.jobOf("c1") is JobEnded,
        what: "the end on the chat");
    expect(room.state.runningJobs, isEmpty);
    expect(host.states.last.jobOf("c1"), const JobEnded(end));
  });
}
