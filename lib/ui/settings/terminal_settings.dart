import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/rootfs.dart";
import "../../providers.dart";
import "rootfs_downloads.dart";
import "../widgets/catalog.dart";
import "../widgets/dialogs.dart";
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
    final usable = rootfsCatalog.where((r) => installed.contains(r.id)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Where commands run",
          description: available
              ? "Android has a shell and almost nothing to run in it. A Linux "
                  "installed here has a package manager, so the agent can add "
                  "whatever a job needs. It runs under proot, on this device, "
                  "with the chat's files at the same paths inside as outside."
              : "This build runs commands on the machine it is on. Installing a "
                  "Linux to run them inside is Android's, where the system's "
                  "own shell has almost nothing in it.",
        ),
        if (available)
          InstalledPicker(
            label: "Commands run on",
            // Null is an answer here rather than an absence, so it is an entry
            // rather than a hint: Android is where commands ran before any of
            // this and where they go back to.
            none: "Android",
            options: {for (final rootfs in usable) rootfs.id: rootfs.name},
            value: selected,
            onPick: (id) => ref.read(appSettingsProvider.notifier).setRootfs(id),
          ),
      ],
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
        onDelete: () => _delete(context, ref),
        // An architecture with no image is a row drawn dead rather than left
        // out, so the reader can see the distribution exists.
        onDownload: rootfs.imageFor(ref.watch(deviceAbiProvider)) == null
            ? null
            : () => ref.read(rootfsDownloadsProvider.notifier).install(rootfs),
      );

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final running = ref.read(appSettingsProvider).rootfsId == rootfs.id;
    final ok = await confirm(
      context,
      title: "Delete ${rootfs.name}?",
      message: running
          ? "Everything installed in it goes with it, and commands go back to "
              "running on Android."
          : "Everything installed in it goes with it.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!ok) return;
    await ref.read(rootfsDownloadsProvider.notifier).delete(rootfs);
  }
}
