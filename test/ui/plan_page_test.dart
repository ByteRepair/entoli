import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:entoli_chat/domain/plan.dart";
import "package:entoli_chat/ui/chat/plan_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<String> chatWithPlan(WidgetTester tester, String? plan) =>
      io(tester, () async {
        final chat = await app.seedChat();
        if (plan != null) {
          final workspace = app.config.workspaceDir(chat.state.id);
          await Directory(workspace).create(recursive: true);
          await File(p.join(workspace, planFileName)).writeAsString(plan);
        }
        return chat.state.id;
      });

  testWidgets("how far it has got, and each task opening to its plan", (
    tester,
  ) async {
    final id = await chatWithPlan(
      tester,
      "# Plan\n\n## Tasks\n\n- [x] read the parser\n"
      "  Start at `parse.dart`.\n- [ ] fix the header\n",
    );
    await app.pump(tester, PlanPage(chatId: id));
    await pumpUntil(tester, find.text("1 of 2 tasks done"));

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.5);
    // One section is no reason for a heading.
    expect(find.text("Tasks"), findsNothing);
    expect(find.byTooltip("Done"), findsOneWidget);
    expect(find.byTooltip("To do"), findsOneWidget);

    expect(find.textContaining("parse.dart"), findsNothing);
    await tester.tap(find.text("1. read the parser"));
    await settleIo(tester);
    expect(find.textContaining("parse.dart"), findsOneWidget);
  });

  testWidgets("several sections each have their heading", (tester) async {
    final id = await chatWithPlan(
      tester,
      "# Plan\n\n## Read\n\n- [x] read the parser\n\n"
      "## Fix\n\n- [ ] fix the header\n",
    );
    await app.pump(tester, PlanPage(chatId: id));
    await pumpUntil(tester, find.text("Read"));

    expect(find.text("Read"), findsOneWidget);
    expect(find.text("Fix"), findsOneWidget);
  });

  testWidgets("a chat with no plan says so", (tester) async {
    final id = await chatWithPlan(tester, null);
    await app.pump(tester, PlanPage(chatId: id));
    await pumpUntil(tester, find.text("This chat has no plan."));
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
