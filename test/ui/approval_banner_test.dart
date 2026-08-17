import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/approval_banner.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// A chat mid-turn with [approval] waiting on the user. The turn is held
  /// open, the way a real one is while the agent waits to be told.
  Future<void> asking(WidgetTester tester, ToolApproval approval) async {
    app.backend.scriptedEvents = [ApprovalRequestEvent(approval)];
    app.backend.hold = Completer<void>();
    addTearDown(() => app.backend.hold?.complete());

    final chat = await io(tester, () => app.repo.createChat());
    final id = chat.state.id;
    app.container.read(selectedChatIdProvider.notifier).state = id;
    await app.pump(tester, const ChatPage(), settle: false);
    await pumpUntil(tester, find.byIcon(Icons.send));
    await io(tester, () => app.container.read(chatControllerProvider(id).notifier).send("build it"));
    await pumpUntil(tester, find.byType(ApprovalBanner));
  }

  const bash = ToolApproval(
    id: "call-1",
    toolName: "bash",
    argumentsJson: '{"command": "rm -rf build && cmake --build ."}',
  );

  // What is being consented to is the command, not the tool: a banner naming
  // only `bash` is asking to be waved through.
  testWidgets("the command is what the banner shows", (tester) async {
    await asking(tester, bash);

    expect(find.text("Allow bash?"), findsOneWidget);
    expect(find.text("rm -rf build && cmake --build ."), findsOneWidget);
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
        argumentsJson: '{"command": "${List.filled(60, "echo hello").join("\\n")}"}',
      ),
    );

    final panel = find.descendant(
      of: find.byType(ApprovalBanner),
      matching: find.byType(SingleChildScrollView),
    );
    expect(tester.getRect(panel).height, lessThanOrEqualTo(ApprovalBanner.mostHeight));
  });

  group("what the panel says", () {
    test("the command of a bash call, and the url of a fetch", () {
      expect(approvalDetail('{"command": "ls -la"}'), "ls -la");
      expect(approvalDetail('{"url": "https://example.com"}'), "https://example.com");
    });

    // The tool is the model's to name and so are its arguments. Showing the
    // JSON is worse than showing the argument and better than showing nothing.
    test("the one argument of a tool that names it something else", () {
      expect(approvalDetail('{"pattern": "TODO"}'), "TODO");
    });

    test("arguments it cannot read are shown as they came", () {
      expect(approvalDetail("not json at all"), "not json at all");
      expect(approvalDetail('{"a": 1, "b": 2}'), contains('"a": 1'));
    });

    test("a call with no arguments has nothing to show", () {
      expect(approvalDetail(null), isNull);
      expect(approvalDetail("  "), isNull);
    });
  });
}
