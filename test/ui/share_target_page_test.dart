import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/share/incoming_shares.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create(handoff: FakeFileHandoff.android()));
  tearDown(() => app.dispose());

  // The whole app under the wrapper, since what is under test is a page pushed
  // over whatever was on screen.
  Future<void> start(WidgetTester tester) async {
    await app.pump(tester, const IncomingShares(child: Scaffold(body: Text("chat"))));
    await settleIo(tester);
  }

  testWidgets("nothing is asked when nothing was shared", (tester) async {
    await start(tester);

    expect(find.text("chat"), findsOneWidget);
    expect(find.textContaining("Share"), findsNothing);
  });

  testWidgets("a share waiting at startup is offered a workspace", (tester) async {
    app.handoff.pendingShare = [incomingFile("notes.md")];
    await start(tester);

    expect(find.text("Share 1 file to"), findsOneWidget);
    expect(find.text("Default"), findsWidgets);
  });

  testWidgets("a share arriving while the app is up is offered one too", (tester) async {
    await start(tester);
    expect(find.text("chat"), findsOneWidget);

    app.handoff.share([incomingFile("a.txt"), incomingFile("b.txt")]);
    await settleIo(tester);

    expect(find.text("Share 2 files to"), findsOneWidget);
  });

  testWidgets("picking the default project writes into its shared workspace",
      (tester) async {
    app.handoff.pendingShare = [incomingFile("notes.md", "from another app")];
    await start(tester);

    await tester.tap(find.text("Default"));
    await settleIo(tester);

    expect(
      File("${app.config.projectWorkspaceDir()}/notes.md").readAsStringSync(),
      "from another app",
    );
    // Closed, so the app is back where the share found it.
    expect(find.text("chat"), findsOneWidget);
    expect(find.text("Share 1 file to"), findsNothing);
  });

  testWidgets("picking a project writes into that project's workspace", (tester) async {
    await io(tester, () => app.repo.createProject("research"));
    app.handoff.pendingShare = [incomingFile("paper.pdf", "bytes")];
    await start(tester);

    await tester.tap(find.text("research"));
    await settleIo(tester);

    expect(
      File("${app.config.projectWorkspaceDir(project: "research")}/paper.pdf")
          .readAsStringSync(),
      "bytes",
    );
  });

  testWidgets("picking a chat writes into that chat's own workspace", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "Refactor the parser"));
    app.handoff.pendingShare = [incomingFile("trace.log", "stack")];
    await start(tester);

    await tester.tap(find.text("Refactor the parser"));
    await settleIo(tester);

    expect(
      File("${app.config.workspaceDir(chat.state.id)}/trace.log").readAsStringSync(),
      "stack",
    );
  });

  testWidgets("a folder's shape survives the share", (tester) async {
    app.handoff.pendingShare = [incomingFile("notes/today/a.txt", "deep")];
    await start(tester);

    await tester.tap(find.text("Default"));
    await settleIo(tester);

    expect(
      File("${app.config.projectWorkspaceDir()}/notes/today/a.txt").readAsStringSync(),
      "deep",
    );
  });

  // Reading it empties it, so a share is offered a workspace exactly once and
  // the page does not come back the moment it is dismissed.
  testWidgets("the same share is not offered twice", (tester) async {
    app.handoff.pendingShare = [incomingFile("notes.md")];
    await start(tester);
    await tester.tap(find.text("Default"));
    await settleIo(tester);

    app.handoff.share(const []);
    await settleIo(tester);

    expect(find.text("Share 1 file to"), findsNothing);
  });
}
