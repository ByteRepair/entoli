import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/local_shell.dart";
import "package:agent_chat/domain/confinement.dart";
import "package:agent_chat/providers.dart";

import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

void main() {
  late TestApp app;

  // What the picker names each environment, and what it reads with none
  // picked: a phone has no shell of its own to offer in its place. Whether
  // one enforces the sandbox is the status card's alone; the tests' host
  // enforces nothing unless told.
  const none = "None";
  const host = "Host";
  const alpine = "Alpine Linux";

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
    expect(
      find.textContaining("tool/android/build.sh arm64-v8a"),
      findsOneWidget,
    );
    // No shell of its own offered in the Linux's place, even here.
    expect(find.text(host), findsNothing);
    expect(find.textContaining("What driver to use"), findsOneWidget);
    expect(find.text("Alpine Linux 3.24.1"), findsNothing);
  });

  testWidgets("where it can run one, the catalog is offered with its size", (
    tester,
  ) async {
    app = TestApp.create(proot: true);
    await pumpTerminal(tester);

    expect(find.text("Alpine Linux 3.24.1"), findsOneWidget);
    expect(find.textContaining("aarch64"), findsOneWidget);
    expect(find.byTooltip("Download"), findsOneWidget);
    expect(find.byTooltip("Delete"), findsNothing);
    expect(find.textContaining("tool/android/build.sh"), findsNothing);

    // Nothing installed yet, so nothing to pick, and no shell of the
    // device's own offered in its place.
    expect(find.text("Commands run on"), findsOneWidget);
    expect(find.text("Nothing downloaded yet."), findsOneWidget);
    expect(find.text("Host"), findsNothing);
    expect(find.text(alpine), findsNothing);
  });

  testWidgets("an architecture this build has no image for is said rather than "
      "offered", (tester) async {
    app = TestApp.create(proot: true, abi: "riscv64");
    await pumpTerminal(tester);

    expect(find.text("No build for this device"), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.download_outlined),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets("downloading one adds it to the picker and leaves it unpicked", (
    tester,
  ) async {
    app = TestApp.create(proot: true);
    await pumpTerminal(tester);

    await tester.tap(find.byTooltip("Download"));
    await settleUntil(
      tester,
      () => app.container.read(installedRootfsProvider).isNotEmpty,
      what: "the download",
    );

    expect(app.container.read(installedRootfsProvider), {"alpine"});
    expect(find.byTooltip("Delete"), findsOneWidget);
    // Installed is not the same as chosen: what commands run on is the user's
    // to say, and a download is not that.
    expect(app.container.read(appSettingsProvider).rootfsId, isNull);
    await tester.tap(find.text(none));
    await settleIo(tester);
    expect(find.text(alpine), findsWidgets);
  });

  testWidgets("picking one is what makes commands run inside it", (
    tester,
  ) async {
    app = TestApp.create(proot: true, linuxes: const {"alpine"});
    await pumpTerminal(tester);

    await tester.tap(find.text(none));
    await settleIo(tester);
    await tester.tap(find.text(alpine).last);
    await settleUntil(
      tester,
      () => app.container.read(appSettingsProvider).rootfsId != null,
      what: "the pick",
    );

    expect(app.container.read(appSettingsProvider).rootfsId, "alpine");
  });

  testWidgets("deleting the one commands run in leaves none picked", (
    tester,
  ) async {
    app = TestApp.create(proot: true, linuxes: const {"alpine"});
    await io(
      tester,
      () =>
          app.container.read(appSettingsProvider.notifier).setRootfs("alpine"),
    );
    await pumpTerminal(tester);

    await tester.tap(find.byTooltip("Delete"));
    await settleIo(tester);
    await tester.tap(find.text("Delete").last);
    // The rescan is the delete's last step, after the unpick's settings write.
    await settleUntil(
      tester,
      () => app.container.read(installedRootfsProvider).isEmpty,
      what: "the delete",
    );

    expect(app.rootfs.deleted, ["alpine"]);
    // Unpicked in the same breath: a setting naming a deleted rootfs would
    // reach proot with nothing to chroot into, mid-turn.
    expect(app.container.read(appSettingsProvider).rootfsId, isNull);
    expect(app.container.read(installedRootfsProvider), isEmpty);
  });

  testWidgets(
    "a download in flight shows what it is doing, and can be stopped",
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
    },
  );

  testWidgets("a desktop with a host shell and no proot shows the picker with "
      "only the host, and no catalog", (tester) async {
    app = TestApp.create(shell: LocalShell(environment: () => const {}));
    await pumpTerminal(tester);

    expect(find.text("Commands run on"), findsOneWidget);
    expect(find.text(host), findsOneWidget);
    expect(find.textContaining("What driver to use"), findsOneWidget);
    // No proot, so no catalog and no build-fault warning.
    expect(find.text("Alpine Linux 3.24.1"), findsNothing);
    expect(find.textContaining("tool/android/build.sh"), findsNothing);
    expect(find.byTooltip("Download"), findsNothing);
  });

  group("the sandbox status card", () {
    const unsupported =
        "This environment does not support sandboxing. Sandbox is not "
        "enforced.";
    const disabled =
        "This environment supports sandboxing, but it is disabled. "
        "Enable it in Settings > Terminal > Sandbox.";
    const enforced = "Sandboxing is enforced.";

    testWidgets("a host that implements no sandbox does not support one", (
      tester,
    ) async {
      app = TestApp.create(shell: LocalShell(environment: () => const {}));
      await pumpTerminal(tester);

      expect(find.text(unsupported), findsOneWidget);
    });

    for (final confinement in [Confinement.landlock, Confinement.seatbelt]) {
      testWidgets("${confinement.name} on the host is enforced", (
        tester,
      ) async {
        app = TestApp.create(
          shell: LocalShell(environment: () => const {}),
          hostConfinement: confinement,
        );
        await pumpTerminal(tester);

        expect(find.text(enforced), findsOneWidget);
      });
    }

    testWidgets("a supporting host with the switch off says where to turn it "
        "on, and the switch does", (tester) async {
      app = TestApp.create(
        shell: LocalShell(environment: () => const {}),
        hostConfinement: Confinement.seatbelt,
      );
      await io(
        tester,
        () => app.container
            .read(projectSettingsProvider(null).notifier)
            .setProjectSandbox(false),
      );
      await pumpTerminal(tester);
      expect(find.text(disabled), findsOneWidget);

      await tester.tap(find.widgetWithText(SwitchListTile, "Sandbox"));
      await settleIo(tester);

      expect(find.text(enforced), findsOneWidget);
    });

    testWidgets("a picked Linux does not enforce it, whatever the host can", (
      tester,
    ) async {
      app = TestApp.create(
        proot: true,
        linuxes: const {"alpine"},
        hostConfinement: Confinement.landlock,
      );
      await io(
        tester,
        () => app.container
            .read(appSettingsProvider.notifier)
            .setRootfs("alpine"),
      );
      await pumpTerminal(tester);

      expect(find.text(unsupported), findsOneWidget);
    });
  });
}
