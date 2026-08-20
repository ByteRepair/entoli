import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

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

  testWidgets("a build with no proot in it says so, and offers nothing to "
      "download", (tester) async {
    app = TestApp.create();
    await pumpTerminal(tester);

    expect(find.textContaining("runs commands on the machine it is on"),
        findsOneWidget);
    expect(find.text("Alpine Linux 3.24.1"), findsNothing);
    expect(find.text("Commands run on"), findsNothing);
  });

  testWidgets("where it can run one, the catalog is offered with its size",
      (tester) async {
    app = TestApp.create(proot: true);
    await pumpTerminal(tester);

    expect(find.text("Alpine Linux 3.24.1"), findsOneWidget);
    expect(find.textContaining("aarch64"), findsOneWidget);
    expect(find.byTooltip("Download"), findsOneWidget);
    expect(find.byTooltip("Delete"), findsNothing);
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

  testWidgets("nothing installed means nothing to pick: commands run on Android",
      (tester) async {
    app = TestApp.create(proot: true);
    await pumpTerminal(tester);

    expect(find.text("Commands run on"), findsOneWidget);
    expect(find.text("Android"), findsOneWidget);
    expect(find.text("Alpine Linux"), findsNothing);
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
    await tester.tap(find.text("Android"));
    await settleIo(tester);
    expect(find.text("Alpine Linux"), findsWidgets);
  });

  testWidgets("picking one is what makes commands run inside it", (tester) async {
    app = TestApp.create(proot: true, linuxes: const {"alpine"});
    await pumpTerminal(tester);

    await tester.tap(find.text("Android"));
    await settleIo(tester);
    await tester.tap(find.text("Alpine Linux").last);
    await settleIo(tester);

    expect(app.container.read(appSettingsProvider).rootfsId, "alpine");
  });

  testWidgets("deleting the one commands run in puts them back on Android",
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
}
