import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/settings/llm_settings.dart" show ImageSection;
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/welcome_page.dart";
import "package:agent_chat/ui/welcome_gate.dart";

import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

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

  Future<void> walkToLast(WidgetTester tester) => next(tester, 12);

  Finder licence() => find.descendant(
      of: find.byKey(const ValueKey("licence")),
      matching: find.byType(Scrollable));

  Finder checkbox() => find.byType(CheckboxListTile);

  // The last page's checkbox, which Done waits on: at the end of the licence
  // until it is ticked.
  Future<void> accept(WidgetTester tester) async {
    await tester.ensureVisible(checkbox());
    await tester.pumpAndSettle();
    await tester.tap(checkbox());
    await settleIo(tester);
  }

  bool inLicence(WidgetTester tester) => find
      .descendant(of: find.byKey(const ValueKey("licence")), matching: checkbox())
      .evaluate()
      .isNotEmpty;

  AppSettings settings() => app.container.read(appSettingsProvider);

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

    await next(tester);
    expect(find.text("Check its work"), findsOneWidget);
    expect(button("Done"), findsOneWidget);
    expect(button("Next"), findsNothing);
  });

  // The last page holds Done until the user ticks the box at the end of the
  // licence; first run has no app behind it to restart, so unticking there
  // just unticks.
  testWidgets("Done is held on the last page until the box is ticked",
      (tester) async {
    await app.pump(tester, const WelcomePage());
    await walkToLast(tester);

    expect(find.textContaining("GNU AFFERO GENERAL PUBLIC LICENSE"),
        findsOneWidget);
    expect(tester.widget<FilledButton>(button("Done")).onPressed, isNull);
    await accept(tester);
    expect(tester.widget<FilledButton>(button("Done")).onPressed, isNotNull);
    // Ticking frees Done and nothing else: Done is what stores it.
    expect(settings().licenceAccepted, isFalse);
    expect(find.byType(WelcomePage), findsOneWidget);
    // Ticked, it leaves the licence for the page under it.
    expect(inLicence(tester), isFalse);
    expect(checkbox(), findsOneWidget);

    await accept(tester);
    expect(tester.widget<FilledButton>(button("Done")).onPressed, isNull);
    expect(settings().licenceAccepted, isFalse);
    expect(app.restart.restarts, 0);
    expect(find.byType(AlertDialog), findsNothing);
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

  testWidgets("the provider page is not left dimmed by a model added in settings",
      (tester) async {
    app.backend.modelList = const [];
    await app.pump(tester, const WelcomePage());
    await walkToProviders(tester);

    await tester.tap(find.text("A provider"));
    await tester.pumpAndSettle();
    expect(find.text("Connect a model"), findsNothing);
    // What the tour watches changing while it is covered is what rebuilt it
    // with no dimensions to read the page from.
    app.backend.modelList = const [
      ModelOption(providerId: "anthropic", modelId: "claude-sonnet-4"),
    ];
    app.container.invalidate(availableModelsProvider);
    await settleIo(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    final fade = tester.widget<Opacity>(find
        .ancestor(of: find.text("Connect a model"), matching: find.byType(Opacity))
        .first);
    expect(fade.opacity, 1);
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
    Future<void> replay(WidgetTester tester) async {
      await app.pump(tester, const SizedBox());
      unawaited(Navigator.of(tester.element(find.byType(SizedBox))).push(
          MaterialPageRoute(
              builder: (_) => const SettingsPage(
                  initialCategory: SettingsCategory.welcome, focus: true))));
      await tester.pumpAndSettle();
      await walkToLast(tester);
    }

    // A replay remembers the tick, pinned outside the licence.
    testWidgets("a replay keeps the tick", (tester) async {
      await io(tester,
          () => app.container.read(appSettingsProvider.notifier).setLicenceAccepted(true));
      await replay(tester);

      expect(tester.widget<CheckboxListTile>(checkbox()).value, isTrue);
      expect(inLicence(tester), isFalse);
      expect(tester.widget<FilledButton>(button("Done")).onPressed, isNotNull);
    });

    testWidgets("unticking there restarts into the tour", (tester) async {
      await io(tester,
          () => app.container.read(appSettingsProvider.notifier).setLicenceAccepted(true));
      await replay(tester);

      await tester.tap(checkbox());
      await tester.pumpAndSettle();
      expect(find.text("By unticking, the app will restart."), findsOneWidget);
      await tester.tap(find.text("Cancel"));
      await tester.pumpAndSettle();
      expect(settings().licenceAccepted, isTrue);
      expect(app.restart.restarts, 0);

      await tester.tap(checkbox());
      await tester.pumpAndSettle();
      await tester.tap(find.text("Restart"));
      await settleIo(tester);
      expect(settings().licenceAccepted, isFalse);
      expect(app.restart.restarts, 1);
    });

    testWidgets("picked wide, the tour fills the pane", (tester) async {
      useWindow(tester, const Size(1200, 800));
      await pumpSettings(tester, app, SettingsCategory.welcome);

      expect(find.byType(WelcomeTour), findsOneWidget);
      expect(find.text("Connect a model"), findsNothing);
    });

    // Replayed from settings, Done still opens the welcome chat, and leaves
    // settings for it.
    testWidgets("Done there opens the welcome chat and leaves", (tester) async {
      await replay(tester);
      await accept(tester);
      await tester.tap(button("Done"));
      // Done makes the welcome chat on disk before it leaves.
      await settleUntil(tester, () => find.byType(WelcomeTour).evaluate().isEmpty,
          what: "the tour leaving");

      expect(find.byType(WelcomeTour), findsNothing);
      expect(settings().licenceAccepted, isTrue);
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
    await accept(tester);
    await tester.tap(button("Done"));
    await settleUntil(tester, () => find.byType(WelcomePage).evaluate().isEmpty,
        what: "the tour leaving");
    expect(find.byType(WelcomePage), findsNothing);
    expect(settings().licenceAccepted, isTrue);

    // Built again over settings now marked seen, the gate stays bare.
    await app.pump(tester, const WelcomeGate(child: SizedBox.shrink()));
    await tester.pump();
    expect(find.byType(WelcomePage), findsNothing);
  });

  // A settings file from before the licence was asked for says only that the
  // tour was seen, which no longer lets the app open.
  testWidgets("a seen tour with no licence tick still opens", (tester) async {
    await io(tester,
        () => app.seedSettings(AppSettings.fromJson({"welcomeSeen": true})));
    await app.pump(tester, const WelcomeGate(child: SizedBox.shrink()));
    await tester.pump();
    expect(find.byType(WelcomePage), findsOneWidget);
  });

  testWidgets("the hint says to scroll until the box is reached",
      (tester) async {
    await app.pump(tester, const WelcomePage());
    await walkToLast(tester);

    double hint() => tester
        .widget<AnimatedOpacity>(find.ancestor(
            of: find.text("Scroll to the end to agree"),
            matching: find.byType(AnimatedOpacity)))
        .opacity;
    expect(hint(), 1);
    await tester.drag(licence(), const Offset(0, -100000));
    await tester.pumpAndSettle();
    expect(hint(), 0);
    await accept(tester);
    expect(find.text("Scroll to the end to agree"), findsNothing);
  });
}