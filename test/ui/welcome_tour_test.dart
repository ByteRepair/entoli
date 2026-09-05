import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/welcome_page.dart";
import "package:agent_chat/ui/welcome_gate.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Finder button(String label) => find.widgetWithText(FilledButton, label);

  Finder previous() => find.widgetWithText(OutlinedButton, "Previous");

  Future<void> walkToLast(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.tap(button("Next"));
      await tester.pumpAndSettle();
    }
  }

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

  testWidgets("Done marks the tour seen and leaves the page", (tester) async {
    await app.pump(tester, const WelcomePage());
    await walkToLast(tester);
    await tester.tap(button("Done"));
    await settleIo(tester, least: 3);

    expect(find.byType(WelcomePage), findsNothing);
    expect(app.container.read(appSettingsProvider).welcomeSeen, isTrue);
  });

  group("in settings", () {
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
      await pumpSettings(tester, app, SettingsCategory.welcome);

      expect(find.byType(WelcomeTour), findsOneWidget);
      expect(find.text("A model to answer"), findsNothing);
    });

    // Done in a settings pane has nothing of its own to leave, so it must not
    // pop the page holding it.
    testWidgets("Done there writes the flag and keeps the page", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.welcome);
      await walkToLast(tester);
      await tester.tap(button("Done"));
      await settleIo(tester, least: 3);

      expect(find.byType(WelcomeTour), findsOneWidget);
      expect(app.container.read(appSettingsProvider).welcomeSeen, isTrue);
    });
  });

  testWidgets("an unseen tour opens over the shell; a seen one does not",
      (tester) async {
    await app.pump(tester, const WelcomeGate(child: SizedBox.shrink()));
    await tester.pump();
    expect(find.byType(WelcomePage), findsOneWidget);

    // Walk it out; the flag lands through the notifier.
    await walkToLast(tester);
    await tester.tap(button("Done"));
    await settleIo(tester, least: 3);
    expect(find.byType(WelcomePage), findsNothing);

    // Built again over settings now marked seen, the gate stays bare.
    await app.pump(tester, const WelcomeGate(child: SizedBox.shrink()));
    await tester.pump();
    expect(find.byType(WelcomePage), findsNothing);
  });
}