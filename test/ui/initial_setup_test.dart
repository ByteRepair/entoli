import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/browser/cdp_browser.dart";
import "package:agent_chat/domain/agent_browser.dart";
import "package:agent_chat/domain/download.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/initial_setup_gate.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  const gate = InitialSetupGate(child: Text("tour"));

  String? browser() => app.container.read(appSettingsProvider).agentBrowser;

  /// A desktop: a browser the app launches, with [helium] as its download.
  TestApp desktop(FakeHelium helium) => TestApp.create(
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
    app = TestApp.create(proot: true);
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

  testWidgets("iOS gets it too", (tester) async {
    app = TestApp.create(abi: "ios");
    await app.pump(tester, gate);
    await settleIo(tester, least: 3);

    expect(rootfs(), "alpine");
    expect(find.text("tour"), findsOneWidget);
  });

  testWidgets("one already installed is only picked", (tester) async {
    app = TestApp.create(proot: true, linuxes: {"alpine"});
    await app.pump(tester, gate);
    await settleIo(tester, least: 3);

    expect(rootfs(), "alpine");
    expect(find.text("tour"), findsOneWidget);
  });

  testWidgets("a failure offers Retry and Skip", (tester) async {
    app = TestApp.create(proot: true);
    app.rootfs.failNext = Exception("offline");
    await app.pump(tester, gate);
    await settleIo(tester);

    expect(find.textContaining("could not be installed"), findsOneWidget);
    await tester.tap(find.text("Retry"));
    await settleIo(tester, least: 3);
    expect(rootfs(), "alpine");

    // Skip leaves the terminal on the host.
    app.dispose();
    app = TestApp.create(proot: true);
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
    app = TestApp.create(proot: true);
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
