import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/domain/shell_job.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/widgets/running_strip.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late FakeBackend backend;

  ShellJob job(int id, String command) => ShellJob(
      id: id, command: command, logPath: "/w/.entoli-jobs/$id.log", pid: 4000 + id);

  final chat = Chat(
    state: ChatState(
      id: "chat-1",
      title: "t",
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    ),
    messages: [
      Message(
        id: "r1",
        role: MessageRole.assistant,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [
          ToolCallPart(
              toolCall: ToolCall(
                  id: "c1",
                  name: "task",
                  argumentsJson:
                      '{"agent":"explore","prompt":"find the parser"}')),
        ],
      ),
    ],
  );

  Future<FakeShellJobs> pumpStrip(WidgetTester tester,
      {bool mirrored = false}) async {
    backend = FakeBackend();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        agentBackendProvider.overrideWithValue(backend),
        isMirroredChatProvider("chat-1").overrideWithValue(mirrored),
      ],
      child: MaterialApp(
        home: Scaffold(
            body: RunningStrip(
                view: ChatViewState(chat: chat))),
      ),
    ));
    return backend.jobsOf("chat-1");
  }

  // A running pill spins, so nothing here settles: pump through the
  // drawer's entrance instead.
  Future<void> open(WidgetTester tester, String pill) async {
    await tester.tap(find.text(pill));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets("jobs are one group, which a tap opens to a pill each and closes",
      (tester) async {
    final jobs = await pumpStrip(tester);
    expect(find.textContaining("running"), findsNothing);

    jobs.jobs.value = [job(1, "npm run dev"), job(2, "make watch")];
    await tester.pump();
    expect(find.text("2 background tasks running"), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);

    await open(tester, "2 background tasks running");
    expect(find.byType(ActionChip), findsNWidgets(2));

    await open(tester, "2 background tasks running");
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets("a mouse wheel scrolls the row sideways", (tester) async {
    final jobs = await pumpStrip(tester);
    jobs.jobs.value = [for (var i = 1; i <= 12; i++) job(i, "server-$i --watch")];
    await tester.pump();
    await open(tester, "12 background tasks running");
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    expect(scroll.offset, 0);

    tester.binding.handlePointerEvent(PointerScrollEvent(
        position: tester.getCenter(find.text("12 background tasks running")),
        scrollDelta: const Offset(0, 120)));
    await tester.pump();
    expect(scroll.offset, 120);
  });

  testWidgets("a pill opens the command and its log, and Stop stops it",
      (tester) async {
    final jobs = await pumpStrip(tester);
    jobs.jobs.value = [job(1, "npm run dev")];
    jobs.logs[1] = "listening on :3000\n";
    await tester.pump();

    await open(tester, "1 background task running");
    await open(tester, "npm run dev");
    expect(find.text("Background job 1"), findsOneWidget);
    // Live, so it ends on the streaming caret.
    expect(find.textContaining("listening on :3000"), findsOneWidget);
    expect(find.text("Running · pid 4001"), findsOneWidget);

    await tester.tap(find.text("Stop"));
    await tester.pump();
    expect(jobs.stopped, [1]);
  });

  testWidgets("a sheet whose job ends keeps its log and loses Stop",
      (tester) async {
    final jobs = await pumpStrip(tester);
    jobs.jobs.value = [job(1, "make")];
    jobs.logs[1] = "built\n";
    await tester.pump();
    await open(tester, "1 background task running");
    await open(tester, "make");

    jobs.jobs.value = const [];
    await tester.pump();
    expect(find.text("Ended"), findsOneWidget);
    expect(find.text("built"), findsOneWidget);
    expect(find.text("Stop"), findsNothing);
  });

  testWidgets("a mirrored chat has no pills: its jobs are elsewhere",
      (tester) async {
    final jobs = await pumpStrip(tester, mirrored: true);
    jobs.jobs.value = [job(1, "npm run dev")];
    await tester.pump();
    expect(find.textContaining("running"), findsNothing);
  });
  testWidgets("sub-agents are a group beside the jobs, and a sub-agent's pill opens its drawer",
      (tester) async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    await app.pump(
        tester,
        Scaffold(
            body: RunningStrip(
                view: ChatViewState(chat: chat, runningSubAgents: {
          "r1": [
            const SubAgentStartEvent(
                id: "c1", agent: "explore", prompt: "find the")
          ],
        }))),
        settle: false);
    app.backend.jobsOf("chat-1").jobs.value = [job(1, "npm run dev")];
    await tester.pump();
    expect(find.text("1 background task running"), findsOneWidget);
    expect(find.text("1 sub-agent running"), findsOneWidget);

    await open(tester, "1 sub-agent running");
    await open(tester, "@explore");
    expect(find.text("Sub-agent @explore"), findsOneWidget);
    // The call's prompt, not the event's cut one.
    expect(find.text("find the parser"), findsOneWidget);
  });
}
