import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/browser/cdp_browser.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart"
    show CliProvider;
import "package:agent_chat/domain/agent_browser.dart";
import "package:agent_chat/domain/download.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/initial_setup_gate.dart";
import "package:agent_chat/ui/settings/downloads.dart" show DownloadState;
import "package:agent_chat/domain/rootfs.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  const gate = InitialSetupGate(child: Text("tour"));

  String? browser() => app.container.read(appSettingsProvider).agentBrowser;

  /// A desktop: a browser the app launches, with [helium] as its download.
  TestApp desktop(FakeHelium helium, {List<CliProvider>? clis}) =>
      TestApp.create(
        clis: clis,
        browser: (config) => CdpBrowser(
          browserDir: p.join(config.dataDir, "browser"),
          picked: () => AppSettings.load(config).agentBrowser,
          visible: () => false,
          embedded: helium,
        ),
      );

  String? rootfs() => app.container.read(appSettingsProvider).rootfsId;

  testWidgets("a phone installs Alpine and picks it before the tour", (
    tester,
  ) async {
    app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
    app.rootfs.installing = Completer();
    await app.pump(tester, gate);
    await tester.pump();

    expect(find.text("Initial setup"), findsOneWidget);
    expect(find.text("tour"), findsNothing);

    app.rootfs.installing!.complete();
    await settleIo(tester, least: 3);
    expect(rootfs(), "alpine");
    expect(find.text("tour"), findsOneWidget);
  });

  testWidgets("iOS gets its x86-64 Linux", (tester) async {
    app = TestApp.create(linuxHost: const EmulatedLinux());
    await app.pump(tester, gate);
    await settleIo(tester, least: 3);

    expect(rootfs(), "alpine64");
    expect(find.text("tour"), findsOneWidget);
  });

  testWidgets("one already installed is only picked", (tester) async {
    app = TestApp.create(
      linuxHost: const ProotLinux("arm64-v8a"),
      linuxes: {"alpine"},
    );
    await app.pump(tester, gate);
    await settleIo(tester, least: 3);

    expect(rootfs(), "alpine");
    expect(find.text("tour"), findsOneWidget);
  });

  testWidgets("a failure offers Retry and Skip", (tester) async {
    app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
    app.rootfs.failNext = Exception("offline");
    await app.pump(tester, gate);
    await settleIo(tester);

    expect(find.textContaining("could not be installed"), findsOneWidget);
    await tester.tap(find.text("Retry"));
    await settleIo(tester, least: 3);
    expect(rootfs(), "alpine");

    // Skip leaves the terminal on the host.
    app.dispose();
    app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
    app.rootfs.failNext = Exception("offline");
    await app.pump(tester, gate);
    await settleIo(tester);
    await tester.tap(find.text("Skip"));
    await tester.pumpAndSettle();
    expect(find.text("tour"), findsOneWidget);
    expect(rootfs(), isNull);
  });

  testWidgets("skipped where no Linux can run, and once the tour is seen", (
    tester,
  ) async {
    app = TestApp.create();
    await app.pump(tester, gate);
    expect(find.text("tour"), findsOneWidget);

    app.dispose();
    app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
    await io(
      tester,
      () => app.seedSettings(AppSettings(licenceAccepted: true)),
    );
    await app.pump(tester, gate);
    await tester.pump();
    expect(find.text("tour"), findsOneWidget);
    expect(rootfs(), isNull);
  });

  testWidgets("a desktop installs Helium and picks it before the tour", (
    tester,
  ) async {
    final helium = FakeHelium()..installing = Completer();
    app = desktop(helium);
    await app.pump(tester, gate);
    await tester.pump();

    expect(find.textContaining("Installing Helium"), findsOneWidget);
    expect(find.text("tour"), findsNothing);

    helium.installing!.complete();
    await settleIo(tester, least: 3);
    expect(browser(), embeddedBrowserId);
    expect(find.text("tour"), findsOneWidget);
  });

  // Each program the tour signs a plan in with is Entoli's own copy,
  // installed one after the other on the same screen before the tour.
  testWidgets("a desktop installs its own copy of each CLI before the tour", (
    tester,
  ) async {
    final claude = FakeCli.claude(installed: false)..installing = Completer();
    final codex = FakeCli.codex(installed: false);
    app = desktop(FakeHelium()..installedVersion = "1", clis: [claude, codex]);
    await app.pump(tester, gate);
    await settleIo(tester, least: 3);

    expect(find.textContaining("Installing Claude CLI"), findsOneWidget);
    expect(find.text("tour"), findsNothing);

    claude.installing!.complete();
    await settleIo(tester, least: 3);
    expect([claude.installs, codex.installs], [1, 1]);
    expect(find.text("tour"), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  // A phone runs the CLIs in its Alpine, so its own copy of each is
  // installed after the Alpine is: proot's on Android, the emulator's x86-64
  // one on iOS.
  test("a phone's plan installs each CLI after its Alpine", () {
    app = TestApp.create(linuxHost: const ProotLinux("arm64-v8a"));
    expect(app.container.read(setupPlanProvider).steps.map((s) => s.name), [
      "Alpine Linux",
      "Claude CLI",
      "Codex CLI",
    ]);
    app.dispose();

    app = TestApp.create(linuxHost: const EmulatedLinux());
    expect(app.container.read(setupPlanProvider).steps.map((s) => s.name), [
      "Alpine Linux (x86-64)",
      "Claude CLI",
      "Codex CLI",
    ]);
  });

  testWidgets("a Helium already on disk is only picked", (tester) async {
    app = desktop(FakeHelium()..installedVersion = "1");
    await app.pump(tester, gate);
    await settleIo(tester, least: 3);

    expect(browser(), embeddedBrowserId);
    expect(find.text("tour"), findsOneWidget);
  });

  testWidgets("a desktop with a browser picked is not asked", (tester) async {
    final helium = FakeHelium();
    app = desktop(helium);
    await io(
      tester,
      () => app.seedSettings(AppSettings(agentBrowser: "/usr/bin/chromium")),
    );
    await app.pump(tester, gate);
    await tester.pump();

    expect(find.text("tour"), findsOneWidget);
    expect(helium.installs, 0);
  });
  test("the plan's policy says how the bar counts", () {
    const step = FakeStep("a");
    const half = DownloadProgress(received: 50, total: 100);
    const unpacking = DownloadProgress(received: 0, total: 0, unpacking: true);

    // The current download alone, with nothing to count while it unpacks.
    expect(const StepProgress().fraction(step, 1, 2, half), 0.5);
    expect(const StepProgress().fraction(step, 1, 2, unpacking), isNull);

    // The whole plan: the second of two steps, half fetched, is a quarter of
    // the way through its own half.
    const plan = PlanProgress(unpackShare: 0.5);
    expect(plan.fraction(step, 1, 2, half), 0.625);
    expect(plan.fraction(step, 1, 2, unpacking), 0.75);
    expect(plan.fraction(step, 0, 2, null), 0);
  });

  testWidgets("a plan's steps run one after another on one screen", (
    tester,
  ) async {
    app = TestApp.create();
    var finished = false;
    await app.pump(
      tester,
      SetupPage(
        plan: const SetupPlan([
          FakeStep("first", finishes: true),
          FakeStep("second"),
        ], progress: PlanProgress()),
        onFinished: () => finished = true,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(app.container.read(fakeStepsDone), {"first"});
    expect(find.text("Installing second, so it is tested."), findsOneWidget);
    expect(find.text("Step 2 of 2 · Starting…"), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );

    app.container.read(fakeStepsDone.notifier).finish("second");
    await tester.pump();
    await tester.pump();
    expect(finished, isTrue);
  });
}

/// Which [FakeStep]s are done.
final fakeStepsDone = NotifierProvider<_Done, Set<String>>(_Done.new);

class _Done extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void finish(String name) => state = {...state, name};
}

/// A step that downloads nothing: started, it is done at once where
/// [finishes], and waits to be finished by hand otherwise.
class FakeStep extends SetupStep {
  const FakeStep(this.name, {this.finishes = false});

  @override
  final String name;
  final bool finishes;

  @override
  String get purpose => "it is tested.";

  @override
  String get settingsPage => "nowhere";

  @override
  ProviderListenable<DownloadState> get downloads => _noDownloads;

  @override
  String get downloadId => name;

  @override
  bool done(WidgetRef ref) => ref.watch(fakeStepsDone).contains(name);

  @override
  void start(WidgetRef ref) {
    if (finishes) ref.read(fakeStepsDone.notifier).finish(name);
  }
}

final _noDownloads = Provider((ref) => const DownloadState());

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
