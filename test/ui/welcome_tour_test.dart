import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/settings/llm_settings.dart" show ImageSection;
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/welcome_page.dart";
import "package:agent_chat/ui/welcome_gate.dart";

import "../fakes.dart";
import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart"
    show CliProvider, HostCliGuest;

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

  // The intro, then the model page.
  Future<void> walkToProviders(WidgetTester tester) => next(tester);

  Future<void> walkToLast(WidgetTester tester) => next(tester, 3);

  Finder licence() => find.descendant(
    of: find.byKey(const ValueKey("licence")),
    matching: find.byType(Scrollable),
  );

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
      .descendant(
        of: find.byKey(const ValueKey("licence")),
        matching: checkbox(),
      )
      .evaluate()
      .isNotEmpty;

  AppSettings settings() => app.container.read(appSettingsProvider);

  testWidgets("walks forward and back through the pages", (tester) async {
    await app.pump(tester, const WelcomePage());

    expect(find.text("Welcome to Entoli"), findsOneWidget);
    // What the app is, on the intro rather than a slide each.
    expect(find.text("Bring your own model"), findsOneWidget);
    await scrollTo(tester, find.text("Yours alone"));
    expect(find.text("Yours alone"), findsOneWidget);
    expect(back(), findsNothing);

    await walkToProviders(tester);
    expect(find.text("Connect a model"), findsOneWidget);
    expect(find.text("4 models ready"), findsOneWidget);
    await tester.tap(back());
    await tester.pumpAndSettle();
    expect(find.text("Welcome to Entoli"), findsOneWidget);

    await walkToProviders(tester);
    // A model answering new chats leaves nothing to pick on the page.
    expect(find.text("LLM"), findsNothing);
    expect(find.text("Title LLM"), findsNothing);

    await next(tester);
    expect(find.text("More to set up"), findsOneWidget);
    // Memory is its own settings page's to switch, not the tour's.
    expect(find.byType(SwitchListTile), findsNothing);
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

    await next(tester);
    expect(find.text("Check its work"), findsOneWidget);
    expect(button("Done"), findsOneWidget);
    expect(button("Next"), findsNothing);
  });

  // The last page holds Done until the user ticks the box at the end of the
  // licence; first run has no app behind it to restart, so unticking there
  // just unticks.
  testWidgets("Done is held on the last page until the box is ticked", (
    tester,
  ) async {
    await app.pump(tester, const WelcomePage());
    await walkToLast(tester);

    expect(
      find.textContaining("GNU AFFERO GENERAL PUBLIC LICENSE"),
      findsOneWidget,
    );
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

  /// What answers new chats, titles and the classifier, in that order.
  List<String?> answering() {
    final s = settings();
    return [s.defaultProviderId, s.titleProviderId, s.classifierProviderId];
  }

  // ChatGPT is Codex CLI. Signed in already, connecting it is nothing to
  // type and no model to pick: it is added and answers everything a first
  // model does, at its own defaults, over the default the walk was seeded
  // with. Connected again, it is the same entry, not a second.
  testWidgets("a signed-in service is added at once, and only once", (
    tester,
  ) async {
    await app.pump(tester, const WelcomePage());
    await walkToProviders(tester);

    await tester.tap(find.text("ChatGPT"));
    await settleIo(tester);

    expect(settings().llmProviders.map((p) => p.api), [LlmApi.codexCli]);
    final id = settings().llmProviders.single.id;
    expect(answering(), [id, id, id]);
    final s = settings();
    expect(
      [s.defaultModelId, s.titleModelId, s.classifierModelId],
      [null, null, null],
    );

    await tester.tap(find.text("ChatGPT"));
    await settleIo(tester);
    expect(settings().llmProviders.map((p) => p.id), [id]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  // Not installed and not signed in: Entoli's own copy is fetched, its
  // sign-in runs, and the page it prints is what the dialog opens. It is
  // added only once the program says it is signed in.
  testWidgets("a service is installed and signed in before it is added", (
    tester,
  ) async {
    final codex = FakeCli.codex(installed: false, signedIn: false);
    app.dispose();
    app = TestApp.create(clis: [FakeCli.claude(), codex]);
    await app.pump(tester, const WelcomePage());
    await walkToProviders(tester);

    await tester.tap(find.text("ChatGPT"));
    await frames(tester);
    expect(codex.installs, 1);
    expect(codex.processes.single.arguments, codex.signInArguments);

    // Split across two writes to its error output, as a terminal's may be.
    codex.processes.single
      ..complain("Open https://auth.openai.com/oauth/auth")
      ..complain("orize?client_id=x\nWaiting…");
    await frames(tester);
    // Opened as a sign-in, which keeps the app in front on a phone so the
    // callback reaches the program.
    await tester.tap(find.text("Open the sign-in page"));
    await tester.pump();
    expect(app.linkOpener.signIns, [
      Uri.parse("https://auth.openai.com/oauth/authorize?client_id=x"),
    ]);
    expect(settings().llmProviders, isEmpty);

    codex.finishSignIn();
    await settleIo(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(settings().llmProviders.map((p) => p.api), [LlmApi.codexCli]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  // A sign-in given up on adds nothing, and leaves no program running.
  testWidgets("a cancelled sign-in adds nothing", (tester) async {
    final claude = FakeCli.claude(signedIn: false);
    app.dispose();
    app = TestApp.create(clis: [claude, FakeCli.codex()]);
    await app.pump(tester, const WelcomePage());
    await walkToProviders(tester);

    await tester.tap(find.text("Claude Pro"));
    await frames(tester);
    await tester.tap(find.text("Cancel"));
    await settleIo(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(settings().llmProviders, isEmpty);
    await expectLater(claude.processes.single.exitCode, completes);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  // A build with nowhere to run a program — an Android one with no proot —
  // is not offered the services that are one.
  testWidgets("a build with nowhere to run a program is offered no service "
      "that is one", (tester) async {
    CliProvider.platformGuest = null;
    addTearDown(() => CliProvider.platformGuest = const HostCliGuest());
    await app.pump(tester, const WelcomePage());
    await walkToProviders(tester);

    expect(find.text("Ollama Cloud"), findsOneWidget);
    expect(find.text("ChatGPT"), findsNothing);
    expect(find.text("Claude Pro"), findsNothing);
  });

  // The provider page holds the tour until some model is reachable: the
  // button is dead and the swipe cannot go around it.
  testWidgets("Next is held on the provider page until a model is reachable", (
    tester,
  ) async {
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

  testWidgets(
    "the provider page is not left dimmed by a model added in settings",
    (tester) async {
      app.backend.modelList = const [];
      await app.pump(tester, const WelcomePage());
      await walkToProviders(tester);

      await scrollTo(tester, find.text("Advanced"));
      await tester.tap(find.text("Advanced"));
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
      final fade = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.text("Connect a model"),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(fade.opacity, 1);
    },
  );

  // Unseeded, unlike the walks, so the model page's gate has something to
  // hold once a model is reachable.
  testWidgets("Next is held on the model page until a model is picked", (
    tester,
  ) async {
    app.dispose();
    app = TestApp.create();
    await app.pump(tester, const WelcomePage());
    await walkToProviders(tester);

    expect(find.text("4 models ready"), findsOneWidget);
    expect(tester.widget<FilledButton>(button("Next")).onPressed, isNull);

    // Picked through the LLM picker the page embeds, which is how a user
    // unlocks it. It sits under the provider rows.
    await scrollTo(tester, find.text("Title LLM"));
    await openPickerFor(tester);
    await tester.tap(find.text("Llama 3").last);
    await settleIo(tester, least: 3);
    expect(tester.widget<FilledButton>(button("Next")).onPressed, isNotNull);

    await next(tester);
    expect(find.text("More to set up"), findsOneWidget);
  });

  group("in settings", () {
    Future<void> replay(WidgetTester tester) async {
      await app.pump(tester, const SizedBox());
      unawaited(
        Navigator.of(tester.element(find.byType(SizedBox))).push(
          MaterialPageRoute(
            builder: (_) => const SettingsPage(
              initialCategory: SettingsCategory.welcome,
              focus: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await walkToLast(tester);
    }

    // A replay remembers the tick, pinned outside the licence.
    testWidgets("a replay keeps the tick", (tester) async {
      await io(
        tester,
        () => app.container
            .read(appSettingsProvider.notifier)
            .setLicenceAccepted(true),
      );
      await replay(tester);

      expect(tester.widget<CheckboxListTile>(checkbox()).value, isTrue);
      expect(inLicence(tester), isFalse);
      expect(tester.widget<FilledButton>(button("Done")).onPressed, isNotNull);
    });

    testWidgets("unticking there restarts into the tour", (tester) async {
      await io(
        tester,
        () => app.container
            .read(appSettingsProvider.notifier)
            .setLicenceAccepted(true),
      );
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

    // Replayed from settings, Done still opens the welcome chat, and leaves
    // settings for it.
    testWidgets("Done there opens the welcome chat and leaves", (tester) async {
      await replay(tester);
      await accept(tester);
      await tester.tap(button("Done"));
      // Done makes the welcome chat on disk before it leaves.
      await settleUntil(
        tester,
        () => find.byType(WelcomeTour).evaluate().isEmpty,
        what: "the tour leaving",
      );

      expect(find.byType(WelcomeTour), findsNothing);
      expect(settings().licenceAccepted, isTrue);
      final id = app.container.read(selectedChatIdProvider);
      expect(id, isNotNull);
      final chat = await io(tester, () => app.repo.openChat(id!));
      expect(chat.state.title, "Welcome to Entoli");
      // The skill is the first message, so its instructions ride every turn;
      // its greeting answers it.
      expect(
        [for (final m in chat.messages) m.role],
        [MessageRole.user, MessageRole.assistant],
      );
      expect(chat.messages.first.plainText, "/entoli-welcome-party");
      expect(chat.messages.last.plainText, contains("What's your name?"));
    });
  });

  testWidgets("an unseen tour opens over the shell; a seen one does not", (
    tester,
  ) async {
    await app.pump(tester, const WelcomeGate(child: SizedBox.shrink()));
    await tester.pump();
    expect(find.byType(WelcomePage), findsOneWidget);

    // Walk it out; the flag lands through the notifier.
    await walkToLast(tester);
    await accept(tester);
    await tester.tap(button("Done"));
    await settleUntil(
      tester,
      () => find.byType(WelcomePage).evaluate().isEmpty,
      what: "the tour leaving",
    );
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
    await io(
      tester,
      () => app.seedSettings(AppSettings.fromJson({"welcomeSeen": true})),
    );
    await app.pump(tester, const WelcomeGate(child: SizedBox.shrink()));
    await tester.pump();
    expect(find.byType(WelcomePage), findsOneWidget);
  });

  testWidgets("the hint says to scroll until the box is reached", (
    tester,
  ) async {
    await app.pump(tester, const WelcomePage());
    await walkToLast(tester);

    double hint() => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.text("Scroll to the end to agree"),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(hint(), 1);
    await tester.drag(licence(), const Offset(0, -100000));
    await tester.pumpAndSettle();
    expect(hint(), 0);
    await accept(tester);
    expect(find.text("Scroll to the end to agree"), findsNothing);
  });
}
