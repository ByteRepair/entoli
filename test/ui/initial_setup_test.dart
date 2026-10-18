import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/initial_setup_gate.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  const gate = InitialSetupGate(child: Text("tour"));

  String? rootfs() => app.container.read(appSettingsProvider).rootfsId;

  testWidgets("a phone installs Alpine and picks it before the tour",
      (tester) async {
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

  testWidgets("skipped where no Linux can run, and once the tour is seen",
      (tester) async {
    app = TestApp.create();
    await app.pump(tester, gate);
    expect(find.text("tour"), findsOneWidget);

    app.dispose();
    app = TestApp.create(proot: true);
    await io(tester, () => app.seedSettings(AppSettings(welcomeSeen: true)));
    await app.pump(tester, gate);
    await tester.pump();
    expect(find.text("tour"), findsOneWidget);
    expect(rootfs(), isNull);
  });
}
