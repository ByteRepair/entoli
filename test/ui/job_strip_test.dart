import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/shell_job.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/widgets/job_strip.dart";

import "../fakes.dart";

void main() {
  late FakeBackend backend;

  ShellJob job(int id, String command, {int? exitCode}) => ShellJob(
        id: id,
        command: command,
        logPath: "/w/.entoli-jobs/$id.log",
        startedAt: DateTime(2026),
        pid: 4000 + id,
        exitCode: exitCode,
        endedAt: exitCode == null ? null : DateTime(2026),
      );

  Future<void> pumpStrip(WidgetTester tester, {bool mirrored = false}) async {
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
  }

  void seed(List<ShellJob> jobs) =>
      (backend.backgroundJobs("chat-1") as ValueNotifier<List<ShellJob>>)
          .value = jobs;

  testWidgets("a pill per job, the ended ones saying how", (tester) async {
    await pumpStrip(tester);
    expect(find.byType(ActionChip), findsNothing);

    seed([job(1, "npm run dev"), job(2, "make test", exitCode: 2)]);
    await tester.pump();
    expect(find.text("npm run dev"), findsOneWidget);
    expect(find.text("make test · exit 2"), findsOneWidget);
  });

  testWidgets("a pill opens the command and its log, and Stop stops it",
      (tester) async {
    await pumpStrip(tester);
    seed([job(1, "npm run dev")]);
    backend.jobLogs[1] = "listening on :3000\n";
    await tester.pump();

    // A running pill spins, so nothing here settles: pump through the
    // dialog's entrance instead.
    await tester.tap(find.text("npm run dev"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("Background job 1"), findsOneWidget);
    expect(find.text("listening on :3000\n"), findsOneWidget);
    expect(find.text("Running · pid 4001"), findsOneWidget);

    await tester.tap(find.text("Stop"));
    await tester.pump();
    expect(backend.stoppedJobs, [1]);
  });

  testWidgets("an ended job is dismissed from its sheet", (tester) async {
    await pumpStrip(tester);
    seed([job(1, "make", exitCode: 0)]);
    await tester.pump();

    await tester.tap(find.text("make · exit 0"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Dismiss"));
    await tester.pumpAndSettle();
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets("a mirrored chat has no pills: its jobs are elsewhere",
      (tester) async {
    await pumpStrip(tester, mirrored: true);
    seed([job(1, "npm run dev")]);
    await tester.pump();
    expect(find.byType(ActionChip), findsNothing);
  });
}
