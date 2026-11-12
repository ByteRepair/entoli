import "dart:io";
import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/browser/cdp_browser.dart";
import "package:agent_chat/domain/agent_browser.dart"
    show EmbeddedBrowser, embeddedBrowserId;
import "package:agent_chat/domain/download.dart";

import "package:agent_chat/app/first_run.dart";
import "package:agent_chat/app/pages/app_page.dart";
import "package:agent_chat/app/pages/cli_sign_in.dart";
import "package:agent_chat/app/pages/setup.dart";
import "package:agent_chat/app/pages/welcome.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/app/settings/spec.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/rootfs.dart";
import "package:agent_chat/providers.dart";

import "../../fakes.dart";
import "../../harness.dart";
import "page_driver.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  AppSettings settings() => app.container.read(appSettingsProvider);

  List<AppPage> stack() => app.container.read(appPagesProvider);

  group("the welcome tour", () {
    setUp(() {
      app = TestApp.create();
      app.seedGlobalDefault(providerId: "anthropic", modelId: "claude-sonnet");
    });

    PageDriver<WelcomeAppPage> open() => PageDriver(app, WelcomeAppPage());

    Future<void> next(PageDriver<WelcomeAppPage> page, [int times = 1]) async {
      for (var i = 0; i < times; i++) {
        await page.tool("next").run();
      }
    }

    test("walks forward and back, Back off the first step", () async {
      final page = open();
      expect(page.findTool("back"), isNull);
      expect(page.page.subtitle(page.reader), "1 of 4");
      await next(page);
      expect(page.page.subtitle(page.reader), "2 of 4");
      await page.tool("back").run();
      expect(page.page.subtitle(page.reader), "1 of 4");
    });

    test("on a first launch it cannot be left but by Done", () async {
      final page = open();
      expect(page.page.held(page.reader), isTrue);
      final replay = PageDriver(app, WelcomeAppPage(replay: true));
      expect(replay.page.held(replay.reader), isFalse);
    });

    test("Done waits for the licence, then opens the welcome chat", () async {
      final page = open();
      await next(page, 3);
      expect(page.tool("done").enabled, isFalse);
      await page.at<ToggleController>("accept").set(true);
      expect(page.tool("done").enabled, isTrue);
      await page.tool("done").run();
      expect(settings().licenceAccepted, isTrue);
      expect(stack(), isEmpty);
      final chats = await app.repo.listChats();
      expect(chats.single.title, "Welcome to Entoli");
    });

    test("Next waits on the model step until a model answers", () async {
      app.dispose();
      app = TestApp.create();
      final page = open();
      await next(page);
      expect(page.tool("next").enabled, isFalse);
      expect(
        page.at<NoticeController>("ready").lines.single.text,
        "Set one up to continue.",
      );
    });

    test("a signed-in service is added at once, and only once", () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final page = open();
      await next(page);
      await page.at<ActionController>("ChatGPT").run();
      expect(settings().llmProviders.map((p) => p.api), [LlmApi.codexCli]);
      final id = settings().llmProviders.single.id;
      await page.at<ActionController>("ChatGPT").run();
      expect(settings().llmProviders.map((p) => p.id), [id]);
    });

    test("a service is installed and signed in before it is added", () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final codex = FakeCli.codex(installed: false, signedIn: false);
      app.dispose();
      app = TestApp.create(clis: [FakeCli.claude(), codex]);
      final page = open();
      await next(page);
      final connecting = page.at<ActionController>("ChatGPT").run();
      final signIn = PageDriver(
        app,
        stack().whereType<CliSignInAppPage>().single,
      );
      await signIn.until(() => codex.processes.isNotEmpty);
      expect(codex.installs, 1);
      codex.processes.single
        ..complain("Open https://auth.openai.com/oauth/auth")
        ..complain("orize?client_id=x\nWaiting…");
      await signIn.until(() => signIn.find<InfoController>("open") != null);
      expect(
        signIn.at<InfoController>("open").rows.single.link,
        Uri.parse("https://auth.openai.com/oauth/authorize?client_id=x"),
      );
      expect(settings().llmProviders, isEmpty);
      codex.finishSignIn();
      await connecting;
      expect(signIn.open, isFalse);
      expect(settings().llmProviders.map((p) => p.api), [LlmApi.codexCli]);
    });

    test(
      "a sign-in given up on adds nothing and leaves nothing running",
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final claude = FakeCli.claude(signedIn: false);
        app.dispose();
        app = TestApp.create(clis: [claude, FakeCli.codex()]);
        final page = open();
        await next(page);
        final connecting = page.at<ActionController>("Claude Pro").run();
        final signIn = PageDriver(
          app,
          stack().whereType<CliSignInAppPage>().single,
        );
        await signIn.until(() => claude.processes.isNotEmpty);
        signIn.close();
        await connecting;
        expect(settings().llmProviders, isEmpty);
        await expectLater(claude.processes.single.exitCode, completes);
      },
    );

    test("unticking it again is a restart, asked first", () async {
      await app.container
          .read(appSettingsProvider.notifier)
          .setLicenceAccepted(true);
      final page = PageDriver(app, WelcomeAppPage(replay: true));
      await next(page, 3);
      final withdraw = page.at<ActionController>("withdraw");
      expect((await withdraw.confirm())?.confirmLabel, "Restart");
      await withdraw.run();
      expect(settings().licenceAccepted, isFalse);
      expect(app.restart.restarts, 1);
    });
  });

  /// The pick's write landed, before the test's directory goes.
  Future<void> written(PageDriver page) => page.until(
    () =>
        File(app.config.settingsFile).existsSync() &&
        !File("${app.config.settingsFile}.writing").existsSync(),
  );

  group("the first run", () {
    test("an unseen tour opens over the app; a seen one does not", () async {
      app = TestApp.create();
      openFirstRun(ContainerReader(app.container));
      expect(stack().single, isA<WelcomeAppPage>());

      app.dispose();
      app = TestApp.create();
      app.seedSettings(AppSettings(licenceAccepted: true));
      openFirstRun(ContainerReader(app.container));
      expect(stack(), isEmpty);
    });

    test("a phone installs Alpine and picks it before the tour", () async {
      app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
      app.rootfs.installing = Completer();
      openFirstRun(ContainerReader(app.container));
      final setup = PageDriver(app, stack().single as SetupAppPage);
      expect(setup.find<CollectionController<SetupStep>>("step"), isNotNull);
      app.rootfs.installing!.complete();
      await setup.until(() => stack().any((p) => p is WelcomeAppPage));
      await written(setup);
      expect(settings().rootfsId, "alpine");
      expect(stack().single, isA<WelcomeAppPage>());
    });

    test("one already installed is only picked", () async {
      app = TestApp.create(
        linuxHost: const ProotLinux("arm64-v8a"),
        linuxes: {"alpine"},
      );
      openFirstRun(ContainerReader(app.container));
      final setup = PageDriver(app, stack().single as SetupAppPage);
      await setup.until(() => stack().any((p) => p is WelcomeAppPage));
      await written(setup);
      expect(settings().rootfsId, "alpine");
    });

    test("a failure offers Retry, and Skip goes on to the tour", () async {
      app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
      app.rootfs.failNext = Exception("offline");
      openFirstRun(ContainerReader(app.container));
      final setup = PageDriver(app, stack().single as SetupAppPage);
      await setup.until(() => setup.find<ActionController>("retry") != null);
      await setup.at<ActionController>("skip").run();
      await setup.until(() => stack().any((p) => p is WelcomeAppPage));
      expect(settings().rootfsId, isNull);
    });

    test("a desktop installs Helium and picks it before the tour", () async {
      final helium = FakeHelium()..installing = Completer();
      app = TestApp.create(
        browser: (config) => CdpBrowser(
          browserDir: p.join(config.dataDir, "browser"),
          picked: () => AppSettings.load(config).agentBrowser,
          visible: () => false,
          embedded: helium,
        ),
      );
      openFirstRun(ContainerReader(app.container));
      final setup = PageDriver(app, stack().single as SetupAppPage);
      expect(
        setup.at<CollectionController<SetupStep>>("step").rows.single.title,
        "Installing Helium",
      );
      helium.installing!.complete();
      await setup.until(() => stack().any((p) => p is WelcomeAppPage));
      await written(setup);
      expect(settings().agentBrowser, embeddedBrowserId);
    });

    test("the plan's policy says how the bar counts", () {
      const half = DownloadProgress(received: 50, total: 100);
      const unpacking = DownloadProgress(
        received: 0,
        total: 0,
        unpacking: true,
      );
      const step = HeliumSetup();
      // The current download alone, nothing to count while it unpacks.
      expect(const StepProgress().fraction(step, 1, 2, half), 0.5);
      expect(const StepProgress().fraction(step, 1, 2, unpacking), isNull);
      // The whole plan: the second of two steps, half fetched.
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
