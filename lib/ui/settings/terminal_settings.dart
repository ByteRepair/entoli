import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/rootfs.dart";
import "../../providers.dart";
import "rootfs_downloads.dart";
import "../widgets/catalog.dart";
import "../widgets/formatting.dart";
import "../widgets/section_header.dart";

/// Where the agent's commands run: Android itself, or a Linux installed here.
/// The picker offers only what is on disk, for the reason the voice pickers do
/// — a choice that fails when it is used rather than when it is made is worse
/// than no choice at all.
class TerminalSection extends ConsumerWidget {
  const TerminalSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(prootAvailableProvider);
    final installed = ref.watch(installedRootfsProvider);
    final selected = ref.watch(appSettingsProvider.select((s) => s.rootfsId));
    // Android answers with an ABI and nothing else does, so an ABI with no
    // proot beside it is this device's build shipping without it.
    final unpackagedAbi = available ? null : ref.watch(deviceAbiProvider);
    final description = available
        ? "Android has a shell and almost nothing to run in it. A Linux "
            "installed here has a package manager, so the agent can add "
            "whatever a job needs. It runs under proot, on this device, with "
            "the chat's files at the same paths inside as outside."
        : unpackagedAbi != null
            ? "Commands run on Android itself. A Linux to run them inside is "
                "downloaded here."
            : "This build runs commands on the machine it is on. Installing a "
                "Linux to run them inside is Android's, where the system's own "
                "shell has almost nothing in it.";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader("Where commands run", description: description),
        if (unpackagedAbi != null) _Unpackaged(abi: unpackagedAbi),
        if (available)
          InstalledPicker(
            label: "Commands run on",
            // Null is an answer here rather than an absence, so it is an entry
            // rather than a hint: Android is where commands ran before any of
            // this and where they go back to.
            none: "Android",
            options: {
              for (final rootfs in rootfsCatalog)
                if (installed.contains(rootfs.id)) rootfs.id: rootfs.name,
            },
            value: selected,
            onPick: (id) => ref.read(appSettingsProvider.notifier).setRootfs(id),
          ),
      ],
    );
  }
}

/// An APK built without proot staged into it, which is a build fault and looks
/// exactly like the feature having been removed: the catalog below is drawn
/// from the same answer, so the page would otherwise be a Terminal page with no
/// terminal on it and nothing saying why. Names the two commands, since the
/// only person who can reach this is whoever built the APK — CI checks the
/// tools are in a release one.
class _Unpackaged extends StatelessWidget {
  const _Unpackaged({required this.abi});

  final String abi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "This build has no proot in it for $abi. Run "
              "tool/android/build.sh $abi and tool/android/stage.sh, then build "
              "the APK again.",
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// The catalog, or nothing at all where no build of proot reached this device.
/// Draws its own divider for the reason the voice catalog does: a line with
/// nothing under it is a rule across the bottom of the page.
class RootfsCatalogSection extends ConsumerWidget {
  const RootfsCatalogSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(prootAvailableProvider)) return const SizedBox.shrink();
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
                    "to running on Android."
                : "Everything installed in it goes with it.",
        // An architecture with no image is a row drawn dead rather than left
        // out, so the reader can see the distribution exists.
        onDownload: rootfs.imageFor(ref.watch(deviceAbiProvider)) == null
            ? null
            : () => ref.read(rootfsDownloadsProvider.notifier).install(rootfs),
      );
}
