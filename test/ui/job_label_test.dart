import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/shell_job.dart";
import "package:agent_chat/ui/chat/widgets/activity_label.dart";

import "../harness.dart";

void main() {
  const call = ToolCall(
      id: "c1",
      name: "bash",
      argumentsJson: '{"command":"npm run dev","background":true}');

  Future<(TestApp, String)> seed(WidgetTester tester) async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    final chatId = await io(tester, () async {
      final chat = await app.repo.createChat();
      final at = DateTime.now();
      await app.repo.append(chat.state.id, [
        ...recordsOf([
          Message(
              id: "m1",
              role: MessageRole.assistant,
              createdAt: at,
              parts: const [MessagePart.toolCall(toolCall: call)]),
        ]),
        ChatRecord.turnEnd(messageId: "m1", reason: TurnEnd.done),
      ]);
      return chat.state.id;
    });
    return (app, chatId);
  }

  testWidgets("a job reads as running, then as how it ended, and its drawer "
      "keeps the end of the log", (tester) async {
    final (app, chatId) = await seed(tester);
    await app.pump(tester, Scaffold(body: JobLabel(chatId: chatId, call: call)));
    // Neither running nor ended: the app it ran under has gone.
    expect(find.text("Background job ended with the app: npm run dev"),
        findsOneWidget);

    final jobs = app.backend.jobsOf(chatId);
    jobs.jobs.value = [
      const ShellJob(
          id: 1, callId: "c1", command: "npm run dev", logPath: "/w/l", pid: 7),
    ];
    await tester.pump();
    expect(find.text("Running in the background: npm run dev"), findsOneWidget);

    jobs.jobs.value = const [];
    jobs.endings.add((
      callId: "c1",
      end: JobEnd(
          jobId: 1,
          exitCode: 1,
          endedAt: DateTime.now(),
          tail: "listening\nboom",
          log: ".entoli-jobs/c1.log"),
    ));
    // The room applies it once its load is in, which is real I/O.
    await settleIo(tester);
    expect(find.text("Background job exited with code 1: npm run dev"),
        findsOneWidget);

    await tester.tap(find.textContaining("exited with code 1"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("Background job 1"), findsOneWidget);
    expect(find.text("Exited with code 1"), findsOneWidget);
    expect(find.text("listening\nboom"), findsOneWidget);
    expect(find.text("Open log"), findsOneWidget);
  });
}
