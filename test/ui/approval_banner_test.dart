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

    expect(find.text("Run this command?"), findsOneWidget);
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

  group("the two always answers", () {
    // Pumped directly: the callbacks are what these tests pin. The held-turn
    // page clips the banner's action row behind the composer's hit area at
    // the default viewport — the same row the Allow/Deny taps reach — so the
    // direct pump asks the banner alone.
    testWidgets("always in chat answers with the approval attached",
        (tester) async {
      ToolApproval? seen;
      var answer = ApprovalResponse.deny;
      await app.pump(
          tester,
          ApprovalBanner(
            approval: bash,
            onAllow: () {},
            onDeny: () {},
            onAlwaysAllowChat: () {
              seen = bash;
              answer = ApprovalResponse.alwaysAllowChat;
            },
            onAlwaysAllowProject: () {},
          ));
      await tester.tap(find.text("Always in chat"));
      await tester.pump();

      expect(answer, ApprovalResponse.alwaysAllowChat);
      expect(seen?.id, "call-1",
          reason: "the derivation reads the rule off the approval");
    });

    testWidgets("always in project answers with the approval attached",
        (tester) async {
      ToolApproval? seen;
      var answer = ApprovalResponse.deny;
      await app.pump(
          tester,
          ApprovalBanner(
            approval: bash,
            onAllow: () {},
            onDeny: () {},
            onAlwaysAllowChat: () {},
            onAlwaysAllowProject: () {
              seen = bash;
              answer = ApprovalResponse.alwaysAllowProject;
            },
          ));
      await tester.tap(find.text("Always in project"));
      await tester.pump();

      expect(answer, ApprovalResponse.alwaysAllowProject);
      expect(seen?.argumentsText, bash.argumentsText);
    });

    testWidgets("a re-prompt banner names the sandbox dirs it agrees to",
        (tester) async {
      ToolApproval? seen;
      const reprompt = ToolApproval(
        id: "call-9-reprompt",
        toolName: "bash",
        argumentsText: "writing /home/yiannis/Projects/x",
        deniedDirs: ["/home/yiannis/Projects/x"],
      );
      await app.pump(
          tester,
          ApprovalBanner(
            approval: reprompt,
            onAllow: () {},
            onDeny: () {},
            onAlwaysAllowChat: () {},
            onAlwaysAllowProject: () => seen = reprompt,
          ));

      expect(find.text("Run this command?"), findsOneWidget);
      expect(find.text("writing /home/yiannis/Projects/x"), findsOneWidget);
      await tester.tap(find.text("Always in project"));
      await tester.pump();
      expect(seen?.deniedDirs, ["/home/yiannis/Projects/x"],
          reason: "the dirs are what an always answer grants");
    });
  });

  group("where the rule would be written", () {
    testWidgets("both always buttons are offered on a local chat",
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await asking(tester, bash);

      expect(find.text("Always in chat"), findsOneWidget);
      expect(find.text("Always in project"), findsOneWidget);
    });

    testWidgets("a mirrored chat hides them", (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // The banner is answered from the other device: the rule is the home
      // device's to write, so this end offers only Allow and Deny.
      await app.pump(
          tester,
          ApprovalBanner(
            approval: bash,
            onAllow: () {},
            onDeny: () {},
          ));

      expect(find.text("Always in chat"), findsNothing);
      expect(find.text("Always in project"), findsNothing);
      expect(find.text("Allow"), findsOneWidget);
      expect(find.text("Deny"), findsOneWidget);
    });

    testWidgets("a directory grant offers no this-turn-only allow",
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await asking(
          tester,
          const ToolApproval(
            id: "call-2",
            toolName: "add_directory",
            argumentsText: "/home/yiannis/Projects/x",
            deniedDirs: ["/home/yiannis/Projects/x"],
          ));

      expect(find.text("Allow"), findsNothing);
      expect(find.text("Always in chat"), findsOneWidget);
      expect(find.text("Always in project"), findsOneWidget);
      expect(find.text("Deny"), findsOneWidget);
    });

    testWidgets("a sandbox re-prompt offers them, asking about the command",
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await asking(
          tester,
          const ToolApproval(
            id: "call-1-reprompt",
            toolName: "bash",
            argumentsText: "podman ps",
            rerun: true,
          ));

      // Always writes a no-sandbox rule for these words.
      expect(find.text("Run it again without the sandbox?"), findsOneWidget);
      expect(find.text("podman ps"), findsOneWidget);
      expect(find.text("Always in chat"), findsOneWidget);
      expect(find.text("Always in project"), findsOneWidget);
      expect(find.text("Allow"), findsOneWidget);
    });
  });

}
