import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/app_shell.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/theme.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    useWindow(tester, size);
    await app.pump(tester, const AppShell());
  }

  testWidgets("wide, the sidebar sits beside the chat", (tester) async {
    await pumpAt(tester, const Size(1200, 800));

    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsNothing);
  });

  // One bar, not the shell's and the chat's. The app opens on the new-chat
  // screen, where there is no chat to name, so it wears the app's own mark.
  testWidgets("narrow, there is one app bar and it opens the sidebar",
      (tester) async {
    await pumpAt(tester, const Size(500, 900));

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text(appTitle), findsOneWidget);
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

  group("the drawer", () {
    Future<void> open(WidgetTester tester, Size size) async {
      await pumpAt(tester, size);
      await tester.tap(find.byIcon(Icons.menu));
      await settleIo(tester);
    }

    testWidgets("takes a phone's whole width", (tester) async {
      await open(tester, const Size(400, 900));

      expect(tester.getSize(find.byType(Drawer)).width, 400);
    });

    // Wide enough that the chat behind it is still worth seeing.
    testWidgets("leaves a tablet's chat showing beside it", (tester) async {
      await open(tester, const Size(800, 900));

      expect(tester.getSize(find.byType(Drawer)).width, lessThan(800));
    });

    // `claimed` is the half the press cannot see: Android forwards one only
    // while the framework has asked for it, and an open drawer does not ask by
    // itself. Without it the app closes on a phone and the rest still passes.
    testWidgets("the back key closes it rather than the app", (tester) async {
      final claimed = frameworkHandlesBack(tester);
      await open(tester, const Size(400, 900));
      expect(find.byType(Sidebar), findsOneWidget);
      expect(claimed.last, isTrue);

      expect(await pressBack(tester), isTrue);

      expect(find.byType(Sidebar), findsNothing);
      expect(claimed.last, isFalse);
    });

    // Shut, there is nothing to close, and back is the app's to answer.
    testWidgets("and is not in the way when it is shut", (tester) async {
      await pumpAt(tester, const Size(400, 900));

      expect(await pressBack(tester), isFalse);
    });
  });
}
