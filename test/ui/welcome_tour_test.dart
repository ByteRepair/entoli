import "dart:async";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/app/first_run.dart";
import "package:agent_chat/data/browser/cdp_browser.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart"
    show CliProvider, HostCliGuest;
import "package:entoli_chat/domain/agent_browser.dart"
    show EmbeddedBrowser, embeddedBrowserId;
import "package:entoli_chat/domain/app_settings.dart";
import "package:entoli_chat/domain/download.dart";
import "package:entoli_chat/domain/llm_provider.dart";
import "package:entoli_chat/domain/models.dart";
import "package:entoli_chat/domain/rootfs.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/initial_setup_gate.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/settings/settings_category.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/welcome_page.dart";

import "../fakes.dart";
import "../harness.dart";

/// The app as the shell opens it: the first run over it once it is up.
class _Shell extends ConsumerStatefulWidget {
  const _Shell();

  @override
  ConsumerState<_Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<_Shell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) openFirstRun(context, ref);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text("app"));
}

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  AppSettings settings() => app.container.read(appSettingsProvider);

  Finder button(String label) => find.widgetWithText(FilledButton, label);

  Finder back() => find.widgetWithText(TextButton, "Back");

  Finder checkbox() => find.byType(CheckboxListTile);

  /// [frames] until [done] holds, for a dialog whose spinner never settles.
  Future<void> pumpTill(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await frames(tester, 1);
    }
    expect(done(), isTrue);
  }

  bool inLicence() => find
      .descendant(
        of: find.byKey(const ValueKey("licence")),
        matching: checkbox(),
      )
      .evaluate()
      .isNotEmpty;

  group("the welcome tour", () {
    setUp(() {
      app = TestApp.create();
      // The model page holds the tour until a model answers new chats, so
      // every walk starts with one seeded.
      app.seedGlobalDefault(providerId: "anthropic", modelId: "claude-sonnet");
    });

    Future<void> next(WidgetTester tester, [int times = 1]) async {
      for (var i = 0; i < times; i++) {
        await tester.tap(button("Next"));
        await tester.pumpAndSettle();
      }
    }

    Future<void> accept(WidgetTester tester) async {
      await tester.ensureVisible(checkbox());
      await tester.pumpAndSettle();
      await tester.tap(checkbox());
      await settleIo(tester);
    }

    testWidgets("walks forward and back through the pages", (tester) async {
      await app.pump(tester, const WelcomePage());

      expect(find.text("Welcome to Entoli"), findsOneWidget);
      expect(find.text("Bring your own model"), findsOneWidget);
      await scrollTo(tester, find.text("Yours alone"));
      expect(back(), findsNothing);

      await next(tester);
      expect(find.text("Connect a Model"), findsOneWidget);
      expect(find.text("4 models ready"), findsOneWidget);
      // A model answering new chats leaves nothing to pick.
      expect(find.text("Title LLM"), findsNothing);
      await tester.tap(back());
      await tester.pumpAndSettle();
      expect(find.text("Welcome to Entoli"), findsOneWidget);

      await next(tester, 2);
      expect(find.text("More to Set Up"), findsOneWidget);
      expect(find.text("Marketplace"), findsOneWidget);
      await scrollTo(tester, find.text("Image generation"));
      await tester.tap(find.text("Image generation"));
      await tester.pumpAndSettle();
      expect(find.text("Image LLM"), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text("More to Set Up"), findsOneWidget);

      await next(tester);
      expect(find.text("Check Its Work"), findsOneWidget);
      expect(button("Done"), findsOneWidget);
      expect(button("Next"), findsNothing);
    });

    testWidgets("a swipe walks too, and fades the page it leaves", (
      tester,
    ) async {
      await app.pump(tester, const WelcomePage());
      await tester.fling(find.byType(PageView), const Offset(-600, 0), 1500);
      await tester.pumpAndSettle();
      expect(find.text("Connect a Model"), findsOneWidget);
      final fade = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.text("Connect a Model"),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(fade.opacity, 1);
    });

    testWidgets("on a first launch it cannot be left but by Done", (
      tester,
    ) async {
      await app.pump(tester, const WelcomePage());
      expect(find.byType(BackButton), findsNothing);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    });

    testWidgets("Done is held on the last page until the box is ticked", (
      tester,
    ) async {
      await app.pump(tester, const WelcomePage());
      await next(tester, 3);

      expect(
        find.textContaining("GNU AFFERO GENERAL PUBLIC LICENSE"),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(button("Done")).onPressed, isNull);
      await accept(tester);
      expect(tester.widget<FilledButton>(button("Done")).onPressed, isNotNull);
      // Ticking frees Done and nothing else: Done is what stores it.
      expect(settings().licenceAccepted, isFalse);
      expect(inLicence(), isFalse);

      await accept(tester);
      expect(tester.widget<FilledButton>(button("Done")).onPressed, isNull);
      expect(app.restart.restarts, 0);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets("the hint says to scroll until the box is reached", (
      tester,
    ) async {
      await app.pump(tester, const WelcomePage());
      await next(tester, 3);

      double hint() => tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.text("Scroll to the end to agree"),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;
      expect(hint(), 1);
      await tester.drag(
        find.descendant(
          of: find.byKey(const ValueKey("licence")),
          matching: find.byType(Scrollable),
        ),
        const Offset(0, -100000),
      );
      await tester.pumpAndSettle();
      expect(hint(), 0);
    });

    /// What answers new chats, titles and the classifier, in that order.
    List<String?> answering() {
      final s = settings();
      return [s.defaultProviderId, s.titleProviderId, s.classifierProviderId];
    }

    testWidgets("a signed-in service is added at once, and only once", (
      tester,
    ) async {
      await app.pump(tester, const WelcomePage());
      await next(tester);

      await tester.tap(find.text("ChatGPT"));
      await settleUntil(
        tester,
        () => settings().llmProviders.isNotEmpty,
        what: "the service being added",
      );
      expect(settings().llmProviders.map((p) => p.api), [LlmApi.codexCli]);
      final id = settings().llmProviders.single.id;
      expect(answering(), [id, id, id]);

      await tester.tap(find.text("ChatGPT"));
      await settleIo(tester, least: 10);
      expect(find.byType(AlertDialog), findsNothing);
      expect(settings().llmProviders.map((p) => p.id), [id]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets("a service is installed and signed in before it is added", (
      tester,
    ) async {
      final codex = FakeCli.codex(installed: false, signedIn: false);
      app.dispose();
      app = TestApp.create(clis: [FakeCli.claude(), codex]);
      app.seedGlobalDefault(providerId: "anthropic", modelId: "claude-sonnet");
      await app.pump(tester, const WelcomePage());
      await next(tester);

      await tester.tap(find.text("ChatGPT"));
      await pumpTill(tester, () => codex.processes.isNotEmpty);
      expect(codex.installs, 1);
      codex.processes.single
        ..complain("Open https://auth.openai.com/oauth/auth")
        ..complain("orize?client_id=x\nWaiting…");
      final open = find.text("Open the sign-in page");
      await pumpTill(tester, () => open.evaluate().isNotEmpty);
      await tester.tap(open);
      await tester.pump();
      expect(app.linkOpener.signIns, [
        Uri.parse("https://auth.openai.com/oauth/authorize?client_id=x"),
      ]);
      expect(settings().llmProviders, isEmpty);

      codex.finishSignIn();
      await pumpTill(tester, () => settings().llmProviders.isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(settings().llmProviders.map((p) => p.api), [LlmApi.codexCli]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets("a cancelled sign-in adds nothing and leaves nothing running", (
      tester,
    ) async {
      final claude = FakeCli.claude(signedIn: false);
      app.dispose();
      app = TestApp.create(clis: [claude, FakeCli.codex()]);
      app.seedGlobalDefault(providerId: "anthropic", modelId: "claude-sonnet");
      await app.pump(tester, const WelcomePage());
      await next(tester);

      await tester.tap(find.text("Claude Pro"));
      await pumpTill(tester, () => claude.processes.isNotEmpty);
      await tester.tap(find.text("Cancel"));
      await settleIo(tester, least: 10);

      expect(find.byType(AlertDialog), findsNothing);
      expect(settings().llmProviders, isEmpty);
      await io(tester, () => claude.processes.single.exitCode);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets("an API service opens its preset's dialog", (tester) async {
      CliProvider.platformGuest = null;
      addTearDown(() => CliProvider.platformGuest = const HostCliGuest());
      await app.pump(tester, const WelcomePage());
      await next(tester);

      // Nowhere to run a program: no service that is one is offered.
      expect(find.text("ChatGPT"), findsNothing);
      expect(find.text("Claude Pro"), findsNothing);
      await tester.tap(find.text("Ollama Cloud"));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets("Next is held on the model page until a model is reachable", (
      tester,
    ) async {
      app.backend.modelList = const [];
      await app.pump(tester, const WelcomePage());
      await next(tester);

      expect(find.text("Set one up to continue."), findsOneWidget);
      expect(tester.widget<FilledButton>(button("Next")).onPressed, isNull);
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(find.text("Connect a Model"), findsOneWidget);

      app.backend.modelList = const [
        ModelOption(providerId: "anthropic", modelId: "claude-sonnet-4"),
      ];
      app.container.invalidate(availableModelsProvider);
      await settleIo(tester);
      expect(find.text("1 model ready"), findsOneWidget);
      expect(tester.widget<FilledButton>(button("Next")).onPressed, isNotNull);
    });

    testWidgets("Next is held until a model answers new chats", (tester) async {
      app.dispose();
      app = TestApp.create();
      await app.pump(tester, const WelcomePage());
      await next(tester);

      expect(find.text("4 models ready"), findsOneWidget);
      expect(tester.widget<FilledButton>(button("Next")).onPressed, isNull);
      await scrollTo(tester, find.text("Title LLM"));
      await openPickerFor(tester);
      await tester.tap(find.text("Llama 3").last);
      await settleIo(tester, least: 3);
      expect(tester.widget<FilledButton>(button("Next")).onPressed, isNotNull);
    });

    group("replayed from Settings", () {
      Future<void> replay(WidgetTester tester) async {
        await app.pump(tester, const SizedBox());
        unawaited(
          Navigator.of(tester.element(find.byType(SizedBox))).push(
            MaterialPageRoute<void>(
              builder: (_) => const SettingsPage(
                initialCategory: SettingsCategory.welcome,
                focus: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text("Take the Welcome Tour"));
        await tester.pumpAndSettle();
        await next(tester, 3);
      }

      testWidgets("a replay keeps the tick, and can be left", (tester) async {
        await io(
          tester,
          () => app.container
              .read(appSettingsProvider.notifier)
              .setLicenceAccepted(true),
        );
        await replay(tester);

        expect(tester.widget<CheckboxListTile>(checkbox()).value, isTrue);
        expect(inLicence(), isFalse);
        expect(find.byType(BackButton), findsOneWidget);
      });

      testWidgets("unticking there restarts, asked first", (tester) async {
        await io(
          tester,
          () => app.container
              .read(appSettingsProvider.notifier)
              .setLicenceAccepted(true),
        );
        await replay(tester);

        await tester.tap(checkbox());
        await tester.pumpAndSettle();
        expect(
          find.text("By unticking, the app will restart."),
          findsOneWidget,
        );
        await tester.tap(find.text("Cancel"));
        await tester.pumpAndSettle();
        expect(settings().licenceAccepted, isTrue);

        await tester.tap(checkbox());
        await tester.pumpAndSettle();
        await tester.tap(find.text("Restart"));
        await settleIo(tester);
        expect(settings().licenceAccepted, isFalse);
        expect(app.restart.restarts, 1);
      });

      testWidgets("Done opens the welcome chat and leaves", (tester) async {
        await replay(tester);
        await accept(tester);
        await tester.tap(button("Done"));
        await settleUntil(
          tester,
          () => find.byType(WelcomeTour).evaluate().isEmpty,
          what: "the tour leaving",
        );

        expect(find.byType(SettingsPage), findsNothing);
        expect(settings().licenceAccepted, isTrue);
        final id = app.container.read(selectedChatIdProvider);
        final chat = await io(tester, () => app.repo.openChat(id!));
        expect(chat.state.title, "Welcome to Entoli");
        expect(
          [for (final m in chat.messages) m.role],
          [MessageRole.user, MessageRole.assistant],
        );
        expect(chat.messages.first.plainText, "/entoli-welcome-party");
        expect(chat.messages.last.plainText, contains("What's your name?"));
      });
    });
  });

  group("the first run", () {
    testWidgets("an unseen tour opens over the app", (tester) async {
      app = TestApp.create();
      await app.pump(tester, const _Shell());
      expect(find.byType(WelcomePage), findsOneWidget);
    });

    testWidgets("a seen tour does not", (tester) async {
      app = TestApp.create();
      await io(
        tester,
        () => app.seedSettings(AppSettings(licenceAccepted: true)),
      );
      await app.pump(tester, const _Shell());
      expect(find.byType(WelcomePage), findsNothing);
      expect(find.text("app"), findsOneWidget);
    });

    testWidgets("a phone installs Alpine and picks it before the tour", (
      tester,
    ) async {
      app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
      app.rootfs.installing = Completer();
      await app.pump(tester, const _Shell(), settle: false);
      await tester.pump();
      await tester.pump();

      expect(find.text("Initial Setup"), findsOneWidget);
      expect(find.byType(PopScope), findsOneWidget);
      expect(find.byType(WelcomePage), findsNothing);

      app.rootfs.installing!.complete();
      await settleUntil(
        tester,
        () => find.byType(WelcomePage).evaluate().isNotEmpty,
        what: "the tour",
      );
      expect(settings().rootfsId, "alpine");
      expect(find.byType(SetupPage), findsNothing);
    });

    testWidgets("one already installed is only picked", (tester) async {
      app = TestApp.create(
        linuxHost: const ProotLinux("arm64-v8a"),
        linuxes: {"alpine"},
      );
      await app.pump(tester, const _Shell(), settle: false);
      await settleUntil(
        tester,
        () => find.byType(WelcomePage).evaluate().isNotEmpty,
        what: "the tour",
      );
      expect(settings().rootfsId, "alpine");
    });

    testWidgets("a failure offers Retry, and Skip goes on to the tour", (
      tester,
    ) async {
      app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
      app.rootfs.failNext = Exception("offline");
      await app.pump(tester, const _Shell(), settle: false);
      await settleUntil(
        tester,
        () => find.text("Retry").evaluate().isNotEmpty,
        what: "the failure",
      );
      expect(find.textContaining("could not be installed"), findsOneWidget);
      expect(find.textContaining("Settings > Terminal"), findsOneWidget);

      await tester.tap(find.text("Skip"));
      await settleUntil(
        tester,
        () => find.byType(WelcomePage).evaluate().isNotEmpty,
        what: "the tour",
      );
      expect(settings().rootfsId, isNull);
    });

    testWidgets("a desktop installs Helium and picks it before the tour", (
      tester,
    ) async {
      final helium = FakeHelium()..installing = Completer();
      app = TestApp.create(
        browser: (config) => CdpBrowser(
          browserDir: p.join(config.dataDir, "browser"),
          picked: () => AppSettings.load(config).agentBrowser,
          visible: () => false,
          embedded: helium,
        ),
      );
      await app.pump(tester, const _Shell(), settle: false);
      await pumpUntil(tester, find.textContaining("Installing Helium"));

      helium.installing!.complete();
      await settleUntil(
        tester,
        () => find.byType(WelcomePage).evaluate().isNotEmpty,
        what: "the tour",
      );
      expect(settings().agentBrowser, embeddedBrowserId);
      // The pick's write landed before the test's directory goes.
      await settleUntil(
        tester,
        () =>
            File(app.config.settingsFile).existsSync() &&
            !File("${app.config.settingsFile}.writing").existsSync(),
      );
    });

    test("the plan's policy says how the bar counts", () {
      const half = DownloadProgress(received: 50, total: 100);
      const unpacking = DownloadProgress(
        received: 0,
        total: 0,
        unpacking: true,
      );
      const step = HeliumSetup();
      expect(const StepProgress().fraction(step, 1, 2, half), 0.5);
      expect(const StepProgress().fraction(step, 1, 2, unpacking), isNull);
      const plan = PlanProgress(unpackShare: 0.5);
      expect(plan.fraction(step, 1, 2, half), 0.625);
      expect(plan.fraction(step, 1, 2, unpacking), 0.75);
      expect(plan.fraction(step, 0, 2, null), 0);
    });

    test("a phone's plan is its Alpine alone", () {
      app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
      final plan = app.container.read(setupPlanProvider);
      expect(plan.steps.single, isA<AlpineSetup>());
    });
  });
}

/// Helium's download, finishing when [installing] does.
class FakeHelium implements EmbeddedBrowser {
  @override
  String? installedVersion;
  Completer<void>? installing;
  var installs = 0;

  @override
  String? get executable => installedVersion == null ? null : "/helium";

  @override
  Future<String> latestVersion() async => "1";

  @override
  Stream<DownloadProgress> install() async* {
    installs++;
    yield const DownloadProgress(received: 0, total: 100);
    await installing?.future;
    installedVersion = "1";
  }

  @override
  Future<void> remove() async => installedVersion = null;
}
