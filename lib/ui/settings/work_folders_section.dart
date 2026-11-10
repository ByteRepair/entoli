import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/project.dart" show ProjectRef;
import "../../domain/work_folders.dart";
import "../../providers.dart";
import "../widgets/add_button_row.dart";
import "../widgets/dialogs.dart" show say;
import "../widgets/section_header.dart";

/// A project's work folders: the directories outside the workspaces that
/// every turn in it may write to, granted up front so no one has to be there
/// to answer for them. They are the project's `writableDirs`, the list an
/// `add_directory` "always for this project" answer extends, so a folder
/// granted on a banner shows here and one removed here is gone from the next
/// call. Folders come from the platform's picker, never typed, and the page
/// only offers this where the paths are this device's and the sandbox is
/// what they open — see "Work folders" in `lib/ui/settings/AGENTS.md`.
class WorkFoldersSection extends ConsumerWidget {
  const WorkFoldersSection({super.key, required this.at});

  final ProjectRef at;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final picked = await ref
        .read(folderPickerProvider)
        .pick(confirmLabel: "Add");
    if (picked == null || !context.mounted) return;
    final refusal = refuseWorkFolder(
      picked,
      dataDir: ref.read(appConfigProvider).dataDir,
    );
    if (refusal != null) {
      say(context, refusal.message);
      return;
    }
    final dirs = ref.read(projectSettingsOf(at)).writableDirs;
    if (dirs.contains(picked)) return;
    await ref.read(projectSettingsOf(at).notifier).setWritableDirs([
      ...dirs,
      picked,
    ]);
  }

  Future<void> _remove(WidgetRef ref, String dir) => ref
      .read(projectSettingsOf(at).notifier)
      .setWritableDirs(
        [...ref.read(projectSettingsOf(at)).writableDirs]..remove(dir),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirs = ref.watch(projectSettingsOf(at).select((s) => s.writableDirs));
    final dataDir = ref.watch(appConfigProvider).dataDir;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Work folders",
          description:
              "Folders outside the workspace that this project's commands "
              "may write to, with nothing to approve.",
        ),
        for (final dir in dirs)
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_outlined),
            title: Text(dir),
            // One the turn is not granted — gone from this device, or over
            // the app's data — is said rather than left looking live.
            subtitle: grantsNow(dir, dataDir: dataDir)
                ? null
                : Text(
                    FileSystemEntity.isDirectorySync(dir)
                        ? "Holds the app's own data, so it grants nothing"
                        : "Missing on this device",
                  ),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              tooltip: "Remove $dir",
              onPressed: () => _remove(ref, dir),
            ),
          ),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text("Add folder"),
            onPressed: () => _add(context, ref),
          ),
        ),
      ],
    );
  }
}
