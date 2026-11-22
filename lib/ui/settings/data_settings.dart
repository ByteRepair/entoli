import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/backup_actions.dart";
import "../../core/formatting.dart" show formatSize;
import "../../data/backup.dart" show Backup, BackupFormatException;
import "../widgets/add_button_row.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/section_header.dart";

/// Settings > Data: everything as one file, out and back in. The work is
/// [BackupBusy]'s; this is the two buttons and the confirm between picking a
/// backup and restoring it.
class DataSettings extends ConsumerWidget {
  const DataSettings({super.key});

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final size = await ref
        .read(backupBusyProvider.notifier)
        .run(() => ref.read(backupBusyProvider.notifier).export());
    if (size != null && context.mounted) {
      notify(context, "Backup written — ${formatSize(size)}.");
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final backups = ref.read(backupBusyProvider.notifier);
    if (backups.refusal case final refusal?) return say(context, refusal);
    final Backup? picked;
    try {
      picked = await backups.pick();
    } on BackupFormatException catch (e) {
      if (context.mounted) say(context, "That file cannot be restored: $e.");
      return;
    }
    final backup = picked;
    if (backup == null || !context.mounted) return;
    final confirmed = await confirm(
      context,
      title: "Restore this backup?",
      message:
          "${describeBackup(backup)}\n\nEverything here now — every chat, "
          "project, workspace and setting — is replaced by what is in it, and "
          "Entoli starts again on what was restored.",
      confirmLabel: "Restore",
      destructive: true,
    );
    if (!confirmed) return;
    await backups.run(() => backups.restore(backup));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(backupBusyProvider);
    return ListView(
      children: [
        const SectionHeader(
          "Backup",
          description:
              "Every chat, project, workspace, prompt and setting as "
              "one zip. Restoring one replaces what is here.",
        ),
        // The icons the explorer uses for the same two directions: a
        // download leaves the app, an upload arrives in it.
        AddButtonRow(
          child: Row(
            spacing: 12,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text("Export"),
                onPressed: busy
                    ? null
                    : () => guarded(context, () => _export(context, ref)),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.upload_file),
                label: const Text("Import"),
                onPressed: busy
                    ? null
                    : () => guarded(context, () => _import(context, ref)),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 2,
          child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
      ],
    );
  }
}
