import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/settings/llm_settings.dart" show ImageSection;
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

  Finder back() => find.widgetWithText(TextButton, "Back");

  Future<void> next(WidgetTester tester, [int times = 1]) async {
    for (var i = 0; i < times; i++) {
      await tester.tap(button("Next"));
      await tester.pumpAndSettle();
    }
  }

  // Six pages of what the app is, then the provider page.
  Future<void> walkToProviders(WidgetTester tester) => next(tester, 6);

  Future<void> walkToLast(WidgetTester tester) => next(tester, 11);

  testWidgets("walks forward and back through the pages", (tester) async {
    await app.pump(tester, const WelcomePage());

    expect(find.text("Welcome to Entoli"), findsOneWidget);
    expect(back(), findsNothing);

    await next(tester);
    expect(find.text("Bring your own model"), findsOneWidget);
    await tester.tap(back());
    await tester.pumpAndSettle();
    expect(find.text("Welcome to Entoli"), findsOneWidget);

    await walkToProviders(tester);
    expect(find.text("Connect a model"), findsOneWidget);
    expect(find.text("4 models ready"), findsOneWidget);

    await next(tester);
    expect(find.text("Pick a model"), findsOneWidget);
    // Both halves of the LLM pickers travel with the page.
    expect(find.text("LLM"), findsOneWidget);
    expect(find.text("Title LLM"), findsOneWidget);

    await next(tester);
    // One switch, and it is the Memory category's "Keep memories".
    expect(find.text("Remember things"), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.text("Memory LLM"), findsNothing);
    final memory = app.container.read(appSettingsProvider).autoMemory;
    await tester.tap(find.text("Enable memories"));
    await settleIo(tester);
    expect(app.container.read(appSettingsProvider).autoMemory, !memory);

    await next(tester);
    expect(find.text("More to set up"), findsOneWidget);
    expect(find.text("Marketplace"), findsOneWidget);
    await scrollTo(tester, find.text("Byte Repair"));
    expect(find.text("Byte Repair"), findsOneWidget);
    // Image generation opens its own settings page, and back returns here.
    await scrollTo(tester, find.text("Image generation"));
    await tester.tap(find.text("Image generation"));
    await tester.pumpAndSettle();
    expect(find.byType(ImageSection), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text("More to set up"), findsOneWidget);

    await next(tester, 2);
    expect(find.text("Yours alone"), findsOneWidget);
    expect(button("Done"), findsOneWidget);
    expect(button("Next"), findsNothing);
  });

  // The provider page holds the tour until some model is reachable: the
  // button is dead and the swipe cannot go around it.
  testWidgets("Next is held on the provider page until a model is reachable",
      (tester) async {
    app.backend.modelList = const [];
    await app.pump(tester, const WelcomePage());
    await walkToProviders(tester);

    expect(find.text("Set one up to continue."), findsOneWidget);
    expect(tester.widget<FilledButton>(button("Next")).onPressed, isNull);
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text("Connect a model"), findsOneWidget);

    app.backend.modelList = const [
      ModelOption(providerId: "anthropic", modelId: "claude-sonnet-4"),
    ];
    app.container.invalidate(availableModelsProvider);
    await settleIo(tester);
    expect(find.text("1 model ready"), findsOneWidget);
    expect(tester.widget<FilledButton>(button("Next")).onPressed, isNotNull);
  });

  // Unseeded, unlike the walks, so the model page's gate has something to
  // hold.
  testWidgets("Next is held on the model page until a model is picked",
      (tester) async {
    app.dispose();
    app = TestApp.create();
    await app.pump(tester, const WelcomePage());
    await walkToProviders(tester);
    await next(tester);

    expect(tester.widget<FilledButton>(button("Next")).onPressed, isNull);

    // Picked through the LLM picker the page embeds, which is how a user
    // unlocks it.
    await openPickerFor(tester);
    await tester.tap(find.text("Llama 3").last);
    await settleIo(tester, least: 3);
    expect(tester.widget<FilledButton>(button("Next")).onPressed, isNotNull);

    await next(tester);
    expect(find.text("Remember things"), findsOneWidget);
  });

  testWidgets("the first-run page has no back arrow", (tester) async {
    await app.pump(tester, const WelcomePage());

    expect(find.byType(BackButton), findsNothing);
  });

  group("in settings", () {
    testWidgets("picked wide, the tour fills the pane", (tester) async {
      useWindow(tester, const Size(1200, 800));
      await pumpSettings(tester, app, SettingsCategory.welcome);

      expect(find.byType(WelcomeTour), findsOneWidget);
      expect(find.text("Connect a model"), findsNothing);
    });

    // Replayed from settings, Done still opens the welcome chat, and leaves
    // settings for it.
    testWidgets("Done there opens the welcome chat and leaves", (tester) async {
      await app.pump(tester, const SizedBox());
      unawaited(Navigator.of(tester.element(find.byType(SizedBox))).push(
          MaterialPageRoute(
              builder: (_) => const SettingsPage(
                  initialCategory: SettingsCategory.welcome, focus: true))));
      await tester.pumpAndSettle();
      await walkToLast(tester);
      await tester.tap(button("Done"));
      await settleIo(tester, least: 3);

      expect(find.byType(WelcomeTour), findsNothing);
      expect(app.container.read(appSettingsProvider).welcomeSeen, isTrue);
      final id = app.container.read(selectedChatIdProvider);
      expect(id, isNotNull);
      final chat = await io(tester, () => app.repo.openChat(id!));
      expect(chat.state.title, "Welcome to Entoli");
      // The skill is the first message, so its instructions ride every turn;
      // its greeting answers it.
      expect([for (final m in chat.messages) m.role],
          [MessageRole.user, MessageRole.assistant]);
      expect(chat.messages.first.plainText, "/entoli-welcome-party");
      expect(chat.messages.last.plainText, contains("What's your name?"));
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