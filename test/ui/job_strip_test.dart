import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/shell_job.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/widgets/job_strip.dart";

import "../fakes.dart";

void main() {
  late FakeBackend backend;

  ShellJob job(int id, String command) => ShellJob(
      id: id, command: command, logPath: "/w/.entoli-jobs/$id.log", pid: 4000 + id);

  Future<FakeShellJobs> pumpStrip(WidgetTester tester,
      {bool mirrored = false}) async {
    backend = FakeBackend();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        agentBackendProvider.overrideWithValue(backend),
        isMirroredChatProvider("chat-1").overrideWithValue(mirrored),
      ],
      child: const MaterialApp(
        home: Scaffold(body: JobStrip(chatId: "chat-1")),
      ),
    ));
    return backend.jobsOf("chat-1");
  }

  // A running pill spins, so nothing here settles: pump through the
  // dialog's entrance instead.
  Future<void> open(WidgetTester tester, String pill) async {
    await tester.tap(find.text(pill));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets("a pill per running job", (tester) async {
    final jobs = await pumpStrip(tester);
    expect(find.byType(ActionChip), findsNothing);

    jobs.jobs.value = [job(1, "npm run dev"), job(2, "make watch")];
    await tester.pump();
    expect(find.byType(ActionChip), findsNWidgets(2));
  });

  testWidgets("a pill opens the command and its log, and Stop stops it",
      (tester) async {
    final jobs = await pumpStrip(tester);
    jobs.jobs.value = [job(1, "npm run dev")];
    jobs.logs[1] = "listening on :3000\n";
    await tester.pump();

    await open(tester, "npm run dev");
    expect(find.text("Background job 1"), findsOneWidget);
    expect(find.text("listening on :3000"), findsOneWidget);
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
    expect(find.byType(ActionChip), findsNothing);
  });
}
