import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/app_shell.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/welcome_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Finder button(String label) => find.widgetWithText(FilledButton, label);

  Finder previous() => find.widgetWithText(OutlinedButton, "Previous");

  testWidgets("walks forward and back through four pages", (tester) async {
    await app.pump(tester, const WelcomePage());

    expect(find.text("Welcome to Entoli"), findsOneWidget);
    expect(button("Previous"), findsNothing);

    await tester.tap(button("Next"));
    await tester.pumpAndSettle();
    expect(find.text("A model to answer"), findsOneWidget);
    // Both halves of the LLM pickers travel with the page.
    expect(find.text("LLM"), findsOneWidget);
    expect(find.text("Title LLM"), findsOneWidget);

    await tester.tap(previous());
    await tester.pumpAndSettle();
    expect(find.text("Welcome to Entoli"), findsOneWidget);

    await tester.tap(button("Next"));
    await tester.pumpAndSettle();
    await tester.tap(button("Next"));
    await tester.pumpAndSettle();
    // The memory page is the category's own sections; the auto-memory half is
    // below the fold of it.
    expect(find.text("Follow @file imports"), findsOneWidget);
    await scrollTo(tester, find.text("Keep memories"));
    // The Memory LLM picker travels under the master gate.
    await tester.tap(find.text("Keep memories"));
    await settleIo(tester);
    expect(find.text("Memory LLM"), findsOneWidget);

    await tester.tap(button("Next"));
    await tester.pumpAndSettle();
    expect(button("Done"), findsOneWidget);
    expect(button("Next"), findsNothing);
  });

  testWidgets("Done marks the tour seen", (tester) async {
    await app.pump(tester, const WelcomePage());
    for (var i = 0; i < 3; i++) {
      await tester.tap(button("Next"));
      await tester.pumpAndSettle();
    }
    await tester.tap(button("Done"));
    await settleIo(tester, least: 3);

    expect(find.byType(WelcomePage), findsNothing);
    expect(app.container.read(appSettingsProvider).welcomeSeen, isTrue);
  });

  group("in settings", () {
    Finder tile(String label) => find.widgetWithText(ListTile, label);

    testWidgets("Welcome is the first item in the list", (tester) async {
      await app.pump(tester, const SettingsPage());

      expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((t) => (t.title as Text?)?.data),
        contains("Welcome"),
      );
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect((tiles.first.title as Text).data, "Welcome");
    });

    testWidgets("picked wide, the tour fills the pane", (tester) async {
      useWindow(tester, const Size(1200, 800));
      await app.pump(tester, const SettingsPage());

      await tester.tap(tile("Welcome"));
      await settleIo(tester);

      expect(find.byType(WelcomeTour), findsOneWidget);
      expect(find.text("A model to answer"), findsNothing);
    });

    testWidgets("and narrow, it is a page over the list", (tester) async {
      await app.pump(tester, const SettingsPage());

      await tester.tap(tile("Welcome"));
      await settleIo(tester);

      expect(find.byType(WelcomeTour), findsOneWidget);
      expect(find.widgetWithText(AppBar, "Welcome"), findsOneWidget);
    });
  });

  testWidgets("an unseen tour opens over the shell; a seen one does not",
      (tester) async {
    await app.pump(tester, const AppShell());
    await tester.pump();
    expect(find.byType(WelcomePage), findsOneWidget);

    // Walk it out; the flag lands through the notifier.
    for (var i = 0; i < 3; i++) {
      await tester.tap(button("Next"));
      await tester.pumpAndSettle();
    }
    await tester.tap(button("Done"));
    await settleIo(tester, least: 3);
    expect(find.byType(WelcomePage), findsNothing);

    // A shell built again over settings now marked seen stays bare.
    await app.pump(tester, const AppShell());
    await tester.pump();
    expect(find.byType(WelcomePage), findsNothing);
  });
}