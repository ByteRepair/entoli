import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/welcome_page.dart";
import "package:agent_chat/ui/welcome_gate.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() {
    app = TestApp.create();
    // The setup page holds the tour until a model is picked, so every walk
    // starts with one seeded.
    app.seedGlobalDefault(providerId: "anthropic", modelId: "claude-sonnet");
  });
  tearDown(() => app.dispose());

  Finder button(String label) => find.widgetWithText(FilledButton, label);

  Finder tile(String label) => find.widgetWithText(ListTile, label);

  Finder previous() => find.widgetWithText(OutlinedButton, "Previous");

  Future<void> walkToLast(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.tap(button("Next"));
      await tester.pumpAndSettle();
    }
  }

  testWidgets("walks forward and back through five pages", (tester) async {
    await app.pump(tester, const WelcomePage());

    expect(find.text("Welcome to Entoli"), findsOneWidget);
    expect(button("Previous"), findsNothing);

    await tester.tap(button("Next"));
    await tester.pumpAndSettle();
    expect(find.text("Provider and Model Setup"), findsOneWidget);
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
    // The memory page is the category's own section: auto-memory alone, the
    // AGENTS.md half of it living in settings only.
    expect(find.text("Agent Memory"), findsOneWidget);
    await scrollTo(tester, find.text("Keep memories"));
    // The Memory LLM picker travels under the master gate.
    await tester.tap(find.text("Keep memories"));
    await settleIo(tester);
    expect(find.text("Memory LLM"), findsOneWidget);

    await tester.tap(button("Next"));
    await tester.pumpAndSettle();
    // The extras page carries Byte Repair with the rest: what its code being
    // formally verified means is said in plain terms there.
    expect(find.text("Byte Repair"), findsOneWidget);
    await scrollTo(tester, find.textContaining("Formally verified coding"));
    expect(find.textContaining("Formally verified coding"), findsOneWidget);

    await tester.tap(button("Next"));
    await tester.pumpAndSettle();
    expect(find.text("What you can do with Entoli"), findsOneWidget);
    expect(button("Done"), findsOneWidget);
    expect(button("Next"), findsNothing);
  });

  // The setup page holds the tour until a model is picked: the button is dead
  // and the swipe cannot go around it. Unseeded, unlike the walks, so the
  // gate has something to hold.
  testWidgets("Next is held on the setup page until a model is picked",
      (tester) async {
    app.dispose();
    app = TestApp.create();
    await app.pump(tester, const WelcomePage());
    await tester.tap(button("Next"));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(button("Next")).onPressed, isNull);

    // Picked through the LLM picker the page embeds, which is how a user
    // unlocks it.
    await openDropdown(tester);
    await tester.tap(find.text("Llama 3").last);
    await settleIo(tester, least: 3);
    expect(tester.widget<FilledButton>(button("Next")).onPressed, isNotNull);

    await tester.tap(button("Next"));
    await tester.pumpAndSettle();
    expect(find.text("Agent Memory"), findsOneWidget);
  });

  testWidgets("the first-run page has no back arrow", (tester) async {
    await app.pump(tester, const WelcomePage());

    expect(find.byType(BackButton), findsNothing);
  });

  group("in settings", () {
    // Welcome is second to last now, below the fold of a test window: scroll
    // it in. The first tile is General's.
    testWidgets("Welcome is in the list", (tester) async {
      await app.pump(tester, const SettingsPage());

      await scrollTo(tester, tile("Welcome"));
      expect(find.widgetWithText(ListTile, "Welcome"), findsOneWidget);
    });

    testWidgets("picked wide, the tour fills the pane", (tester) async {
      useWindow(tester, const Size(1200, 800));
      await pumpSettings(tester, app, SettingsCategory.welcome);

      expect(find.byType(WelcomeTour), findsOneWidget);
      expect(find.text("Provider and Model Setup"), findsNothing);
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