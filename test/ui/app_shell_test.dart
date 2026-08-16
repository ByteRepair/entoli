import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/app_shell.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await app.pump(tester, const AppShell());
  }

  testWidgets("wide, the sidebar sits beside the chat", (tester) async {
    await pumpAt(tester, const Size(1200, 800));

    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsNothing);
  });

  // One bar, not the shell's and the chat's: the mark is where it can give way
  // to the chat's title.
  testWidgets("narrow, there is one app bar and it opens the sidebar",
      (tester) async {
    await pumpAt(tester, const Size(500, 900));

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text("Entoli"), findsOneWidget);
    expect(find.byType(Sidebar), findsNothing);

    await tester.tap(find.byIcon(Icons.menu));
    await settleIo(tester);

    expect(find.byType(Sidebar), findsOneWidget);
  });

  testWidgets("a chat picked in the drawer closes it and opens in the pane",
      (tester) async {
    await io(tester, () => app.seedChat(title: "old chat"));
    await pumpAt(tester, const Size(500, 900));

    await tester.tap(find.byIcon(Icons.menu));
    await settleIo(tester);
    await tester.tap(find.text("old chat"));
    await settleIo(tester);

    expect(find.byType(Drawer), findsNothing);
    expect(app.container.read(selectedChatIdProvider), isNotNull);
  });
}
