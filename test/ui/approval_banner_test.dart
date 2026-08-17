import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/widgets/approval_banner.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> asking(WidgetTester tester, ToolApproval approval) => heldTurn(
        tester,
        app,
        event: ApprovalRequestEvent(approval),
        until: find.byType(ApprovalBanner),
      );

  const bash = ToolApproval(
    id: "call-1",
    toolName: "bash",
    argumentsJson: '{"command": "rm -rf build && cmake --build ."}',
    argumentsText: "rm -rf build && cmake --build .",
  );

  // What is being consented to is the command, not the tool: a banner naming
  // only `bash` is asking to be waved through.
  testWidgets("the command is what the banner shows", (tester) async {
    await asking(tester, bash);

    expect(find.text("Allow bash?"), findsOneWidget);
    expect(find.text("rm -rf build && cmake --build ."), findsOneWidget);
  });

  // A tool that words nothing is still worth showing: the arguments as they
  // came beat a banner with only a name on it.
  testWidgets("a call that words nothing falls back to its arguments",
      (tester) async {
    await asking(
      tester,
      const ToolApproval(
        id: "call-3",
        toolName: "mystery",
        argumentsJson: '{"pattern": "TODO"}',
      ),
    );

    expect(find.text('{"pattern": "TODO"}'), findsOneWidget);
  });

  testWidgets("a call with no arguments shows the name alone", (tester) async {
    await asking(tester, const ToolApproval(id: "call-4", toolName: "sync"));

    expect(find.text("Allow sync?"), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ApprovalBanner),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
  });

  testWidgets("allowing and denying both reach the backend", (tester) async {
    await asking(tester, bash);

    await tester.tap(find.text("Allow"));
    await tester.pump();

    expect(app.backend.approvals.single.approvalId, "call-1");
    expect(app.backend.approvals.single.response, ApprovalResponse.allow);
    expect(find.byType(ApprovalBanner), findsNothing);
  });

  testWidgets("denying says so rather than saying nothing", (tester) async {
    await asking(tester, bash);

    await tester.tap(find.text("Deny"));
    await tester.pump();

    expect(app.backend.approvals.single.response, ApprovalResponse.deny);
    expect(find.byType(ApprovalBanner), findsNothing);
  });

  // A command of any length stays readable without the banner growing over the
  // conversation it is asking about.
  testWidgets("a long command scrolls inside the banner rather than growing it",
      (tester) async {
    await asking(
      tester,
      ToolApproval(
        id: "call-2",
        toolName: "bash",
        argumentsText: List.filled(60, "echo hello").join("\n"),
      ),
    );

    final panel = find.descendant(
      of: find.byType(ApprovalBanner),
      matching: find.byType(SingleChildScrollView),
    );
    expect(tester.getRect(panel).height, lessThanOrEqualTo(ApprovalBanner.mostHeight));
  });

}
