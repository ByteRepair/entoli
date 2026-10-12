import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/local_shell.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  Future<void> pumpTerminal(WidgetTester tester) async {
    useWindow(tester, const Size(1200, 1600));
    await pumpSettings(tester, app, SettingsCategory.terminal);
  }

  testWidgets("a platform with no shell says so, and offers nothing to "
      "download", (tester) async {
    app = TestApp.create();
    await pumpTerminal(tester);

    expect(find.textContaining("no terminal"), findsOneWidget);
    expect(find.text("Alpine Linux 3.24.1"), findsNothing);
    expect(find.text("Commands run on"), findsNothing);
    expect(find.textContaining("tool/android/build.sh"), findsNothing);
  });

  testWidgets("a phone whose build has no proot in it blames the build, not "
      "the device", (tester) async {
    app = TestApp.create(abi: "arm64-v8a");
    await pumpTerminal(tester);

    expect(find.textContaining("no proot in it for arm64-v8a"), findsOneWidget);
    expect(find.textContaining("tool/android/build.sh arm64-v8a"), findsOneWidget);
    expect(find.text("Host"), findsOneWidget);
    expect(find.textContaining("What driver to use"), findsOneWidget);
    expect(find.text("Alpine Linux 3.24.1"), findsNothing);
  });

  testWidgets("where it can run one, the catalog is offered with its size",
      (tester) async {
    app = TestApp.create(proot: true);
    await pumpTerminal(tester);

    expect(find.text("Alpine Linux 3.24.1"), findsOneWidget);
    expect(find.textContaining("aarch64"), findsOneWidget);
    expect(find.byTooltip("Download"), findsOneWidget);
    expect(find.byTooltip("Delete"), findsNothing);
    expect(find.textContaining("tool/android/build.sh"), findsNothing);

    // Nothing installed yet, so nothing to pick: commands run on the host.
    expect(find.text("Commands run on"), findsOneWidget);
    expect(find.text("Host"), findsOneWidget);
    expect(find.text("Alpine Linux"), findsNothing);
  });

  testWidgets("an architecture this build has no image for is said rather than "
      "offered", (tester) async {
    app = TestApp.create(proot: true, abi: "riscv64");
    await pumpTerminal(tester);

    expect(find.text("No build for this device"), findsOneWidget);
    final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.download_outlined));
    expect(button.onPressed, isNull);
  });

  testWidgets("downloading one adds it to the picker and leaves it unpicked",
      (tester) async {
    app = TestApp.create(proot: true);
    await pumpTerminal(tester);

    await tester.tap(find.byTooltip("Download"));
    await settleIo(tester);

    expect(app.container.read(installedRootfsProvider), {"alpine"});
    expect(find.byTooltip("Delete"), findsOneWidget);
    // Installed is not the same as chosen: what commands run on is the user's
    // to say, and a download is not that.
    expect(app.container.read(appSettingsProvider).rootfsId, isNull);
    await tester.tap(find.text("Host"));
    await settleIo(tester);
    expect(find.text("Alpine Linux"), findsWidgets);
  });

  testWidgets("picking one is what makes commands run inside it", (tester) async {
    app = TestApp.create(proot: true, linuxes: const {"alpine"});
    await pumpTerminal(tester);

    await tester.tap(find.text("Host"));
    await settleIo(tester);
    await tester.tap(find.text("Alpine Linux").last);
    await settleIo(tester);

    expect(app.container.read(appSettingsProvider).rootfsId, "alpine");
  });

  testWidgets("deleting the one commands run in puts them back on the host",
      (tester) async {
    app = TestApp.create(proot: true, linuxes: const {"alpine"});
    await io(tester,
        () => app.container.read(appSettingsProvider.notifier).setRootfs("alpine"));
    await pumpTerminal(tester);

    await tester.tap(find.byTooltip("Delete"));
    await settleIo(tester);
    await tester.tap(find.text("Delete").last);
    await settleIo(tester);

    expect(app.rootfs.deleted, ["alpine"]);
    // Unpicked in the same breath: a setting naming a deleted rootfs would
    // reach proot with nothing to chroot into, mid-turn.
    expect(app.container.read(appSettingsProvider).rootfsId, isNull);
    expect(app.container.read(installedRootfsProvider), isEmpty);
  });

  testWidgets("a download in flight shows what it is doing, and can be stopped",
      (tester) async {
    app = TestApp.create(proot: true);
    app.rootfs.installing = Completer<void>();
    await pumpTerminal(tester);

    await tester.tap(find.byTooltip("Download"));
    await settleIo(tester);

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byTooltip("Cancel"), findsOneWidget);

    await tester.tap(find.byTooltip("Cancel"));
    await settleIo(tester);

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(app.container.read(installedRootfsProvider), isEmpty);
  });

  testWidgets("a desktop with a host shell and no proot shows the picker with "
      "only the host, and no catalog", (tester) async {
    app = TestApp.create(shell: LocalShell(environment: () => const {}));
    await pumpTerminal(tester);

    expect(find.text("Commands run on"), findsOneWidget);
    expect(find.text("Host"), findsOneWidget);
    expect(find.textContaining("What driver to use"), findsOneWidget);
    // No proot, so no catalog and no build-fault warning.
    expect(find.text("Alpine Linux 3.24.1"), findsNothing);
    expect(find.textContaining("tool/android/build.sh"), findsNothing);
    expect(find.byTooltip("Download"), findsNothing);
  });
}
