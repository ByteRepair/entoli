import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/rootfs.dart";
import "../../providers.dart";
import "rootfs_downloads.dart";
import "../widgets/dialogs.dart";
import "../widgets/formatting.dart";
import "../widgets/resettable_field.dart";
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
          LabelledField(
            label: "Commands run on",
            child: DropdownButton<String?>(
              isExpanded: true,
              // A setting naming a deleted distribution is a value no item
              // carries, which `DropdownButton` asserts on.
              value: usable.any((r) => r.id == selected) ? selected : null,
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text("Android")),
                for (final rootfs in usable)
                  DropdownMenuItem(value: rootfs.id, child: Text(rootfs.name)),
              ],
              onChanged: (id) => ref.read(appSettingsProvider.notifier).setRootfs(id),
            ),
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
    final theme = Theme.of(context);
    // Its own row only: a progress event names one distribution, and watching
    // the whole state would rebuild every tile for it.
    final progress =
        ref.watch(rootfsDownloadsProvider.select((s) => s.active[rootfs.id]));
    final failure =
        ref.watch(rootfsDownloadsProvider.select((s) => s.failures[rootfs.id]));
    final image = rootfs.imageFor(ref.watch(deviceAbiProvider));

    return ListTile(
      isThreeLine: failure != null || progress != null,
      title: Text("${rootfs.name} ${rootfs.version}"),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(image == null
              ? "No build for this device"
              : "${image.arch} · ${formatSize(image.bytes)} to download · "
                  "${rootfs.packageManager} for everything else"),
          if (failure != null)
            Text(
              failure,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
                value: progress.unpacking ? null : progress.fraction),
            const SizedBox(height: 4),
            Text(
              progress.unpacking
                  ? "Unpacking…"
                  : "${formatSize(progress.received)} of ${formatSize(progress.total)}",
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
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
  Widget build(BuildContext context, WidgetRef ref) {
    if (downloading) {
      return IconButton(
        icon: const Icon(Icons.close),
        tooltip: "Cancel",
        onPressed: () => ref.read(rootfsDownloadsProvider.notifier).cancel(rootfs.id),
      );
    }
    if (ref.watch(installedRootfsProvider).contains(rootfs.id)) {
      return IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: "Delete",
        onPressed: () => _delete(context, ref),
      );
    }
    final image = rootfs.imageFor(ref.watch(deviceAbiProvider));
    return IconButton(
      icon: const Icon(Icons.download_outlined),
      tooltip: "Download",
      onPressed: image == null
          ? null
          : () => ref.read(rootfsDownloadsProvider.notifier).install(rootfs),
    );
  }

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
