import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/rootfs.dart";
import "../../providers.dart";
import "rootfs_downloads.dart";
import "../widgets/catalog.dart";
import "../widgets/formatting.dart";
import "../widgets/section_header.dart";
import "../widgets/settings_warning_banner.dart";

/// Where the agent's commands run: the host driver — the machine's own shell,
/// which every native platform has — or, where this build ships proot, a Linux
/// installed from the catalog under it. The picker offers only what is on disk,
/// for the reason the voice pickers do — a choice that fails when it is used
/// rather than when it is made is worse than no choice at all. A platform with
/// no shell at all, which is a browser, gets the header and nothing under it.
class TerminalSection extends ConsumerWidget {
  const TerminalSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canRun = ref.watch(shellProvider.select((s) => s.canRunCommands));
    final abi = ref.watch(deviceAbiProvider);
    final available = ref.watch(prootAvailableProvider);
    // A Linux can run where this build carries proot (Android) or where the
    // in-process emulator does (iOS, whose ABI is the "ios" key its catalog
    // is keyed on). The web answers null with no proot: nothing could ever
    // run there. iOS with no Linux installed reads as "nothing to run" in
    // [canRunCommands], but the catalog below is the way one gets installed,
    // so the section stays for it.
    final canHostALinux = available || abi == "ios";
    if (!canRun && !canHostALinux) {
      return SectionHeader(
        "Where commands run",
        description: "This platform has no terminal, so the agent has no "
            "commands to run.",
      );
    }
    final installed = ref.watch(installedRootfsProvider);
    final selected = ref.watch(appSettingsProvider.select((s) => s.rootfsId));
    // Android is the only platform whose ABI with no proot beside it is this
    // device's build shipping without it — a fault of the APK. iOS carries no
    // proot by design; its shell is the in-process emulator, and its catalog
    // rides on the "ios" ABI the device answers with.
    final unpackagedAbi =
        available || abi == null || abi == "ios" ? null : abi;
    final description = "What driver to use when running commands. Determines "
        "the environment commands will run in."
        "${available
            ? " The host system is quite limited. It's recommended to install "
                "a virtual file-system to be able to install binaries."
            : ""}";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader("Where commands run", description: description),
        // An APK built without proot staged into it is a build fault and looks
        // exactly like the feature having been removed: the catalog below is
        // drawn from the same answer, so the page would otherwise be a Terminal
        // page with no terminal on it and nothing saying why. The banner names
        // the two commands, since the only person who can reach this is whoever
        // built the APK — CI checks the tools are in a release one.
        if (unpackagedAbi != null)
          SettingsWarningBanner(
            icon: Icons.warning_amber_rounded,
            color: Theme.of(context).colorScheme.error,
            text: "This build has no proot in it for $unpackagedAbi. Run "
                "tool/android/build.sh $unpackagedAbi and "
                "tool/android/stage.sh, then build the APK again.",
          ),
        InstalledPicker(
          label: "Commands run on",
          // Null is an answer here rather than an absence, so it is an entry
          // rather than a hint: the host is where commands ran before any of
          // this and where they go back to. An installed rootfs is offered
          // wherever a Linux can run at all — proot on Android, the emulator
          // on iOS.
          none: "Host",
          options: {
            for (final rootfs in rootfsCatalog)
              if ((available || abi == "ios") && installed.contains(rootfs.id))
                rootfs.id: rootfs.name,
          },
          value: selected,
          onPick: (id) => ref.read(appSettingsProvider.notifier).setRootfs(id),
        ),
      ],
    );
  }
}

/// The catalog, or nothing at all where this device could not run a Linux
/// even with one installed — no proot and no in-process emulator. Draws its
/// own divider for the reason the voice catalog does: a line with
/// nothing under it is a rule across the bottom of the page.
class RootfsCatalogSection extends ConsumerWidget {
  const RootfsCatalogSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canHostALinux = ref.watch(prootAvailableProvider) ||
        ref.watch(deviceAbiProvider) == "ios";
    if (!canHostALinux) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SectionHeader(
          "Available",
          description: "Downloaded once and kept outside the app's data, so a "
              "backup does not carry it and a restore does not delete it.",
        ),
        for (final rootfs in rootfsCatalog) RootfsTile(rootfs: rootfs),
      ],
    );
  }
}

/// One distribution as a row: what it is, what it costs, and the single button
/// that applies to it — download, cancel, or delete, never more than one.
class RootfsTile extends ConsumerWidget {
  const RootfsTile({super.key, required this.rootfs});

  final Rootfs rootfs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Its own row only: a progress event names one distribution, and watching
    // the whole state would rebuild every tile for it.
    final progress =
        ref.watch(rootfsDownloadsProvider.select((s) => s.active[rootfs.id]));
    final failure =
        ref.watch(rootfsDownloadsProvider.select((s) => s.failures[rootfs.id]));
    final image = rootfs.imageFor(ref.watch(deviceAbiProvider));

    return CatalogTile(
      title: Text("${rootfs.name} ${rootfs.version}"),
      summary: image == null
          ? "No build for this device"
          : "${image.arch} · ${formatSize(image.bytes)} to download · "
              "${rootfs.packageManager} for everything else",
      failure: failure,
      progress: progress,
      trailing: _Action(rootfs: rootfs, downloading: progress != null),
    );
  }
}

/// Reads what it needs itself rather than being handed it: neither the
/// installed set nor the device's ABI appears in the row above, and passing
/// them down would rebuild the whole `ListTile` for a button.
class _Action extends ConsumerWidget {
  const _Action({required this.rootfs, required this.downloading});

  final Rootfs rootfs;
  final bool downloading;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CatalogAction(
        downloading: downloading,
        installed: ref.watch(installedRootfsProvider).contains(rootfs.id),
        onCancel: () => ref.read(rootfsDownloadsProvider.notifier).cancel(rootfs.id),
        onDelete: () => ref.read(rootfsDownloadsProvider.notifier).delete(rootfs),
        deleteTitle: "Delete ${rootfs.name}?",
        // What it costs to agree depends on whether commands are running in it.
        deleteMessage:
            ref.watch(appSettingsProvider.select((s) => s.rootfsId)) == rootfs.id
                ? "Everything installed in it goes with it, and commands go back "
                    "to running on the host."
                : "Everything installed in it goes with it.",
        // An architecture with no image is a row drawn dead rather than left
        // out, so the reader can see the distribution exists.
        onDownload: rootfs.imageFor(ref.watch(deviceAbiProvider)) == null
            ? null
            : () => ref.read(rootfsDownloadsProvider.notifier).install(rootfs),
      );
}
