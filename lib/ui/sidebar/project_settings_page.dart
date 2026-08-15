import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "../widgets/destructive_button.dart";
import "../widgets/dialogs.dart";
import "sidebar.dart";

/// Delete a project, its chats, and its shared workspace. Confirms first,
/// deselects the project and its chats, and invalidates the lists so the UI
/// reflects the deletion. Shared by the sidebar's project menu and the
/// project settings page so the message and the invalidations agree.
Future<void> deleteProject(
  BuildContext context,
  WidgetRef ref,
  String project, {
  bool popToRoot = false,
}) async {
  final count = (ref.read(chatListProvider).value ?? const [])
      .where((c) => c.project == project)
      .length;
  final confirmed = await _confirmDeleteProject(context, project, count);
  if (!confirmed) return;
  await ref.read(chatRepositoryProvider).deleteProject(project);
  ref.read(selectedProjectProvider.notifier).select(null);
  ref.read(selectedChatIdProvider.notifier).select(null);
  ref.invalidate(projectListProvider);
  ref.invalidate(chatListProvider);
  if (context.mounted && popToRoot) Navigator.of(context).popUntil((r) => r.isFirst);
}

Future<bool> _confirmDeleteProject(BuildContext context, String project, int count) {
  return confirm(
    context,
    title: "Delete project?",
    message: "Delete \"$project\", its $count ${count == 1 ? "chat" : "chats"} "
        "and its shared workspace? This cannot be undone.",
    confirmLabel: "Delete",
    destructive: true,
  );
}

class ProjectSettingsPage extends ConsumerWidget {
  const ProjectSettingsPage({super.key, required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats =
        (ref.watch(chatListProvider).value ?? const [])
            .where((c) => c.project == project)
            .toList();
    final count = chats.length;
    final path = ref.watch(appConfigProvider).projectDir(project: project).path;

    return Scaffold(
      appBar: AppBar(title: const Text("Project settings")),
      body: ListView(
        children: [
          _CopyField(
            label: "Project name",
            value: project,
            snack: "Copied project name",
          ),
          const Divider(),
          _CopyField(
            label: "Path",
            value: path,
            snack: "Copied project path",
          ),
          const Divider(),
          ListTile(
            title: const Text("Chats"),
            trailing: Text("$count"),
          ),
          const Divider(),
          DestructiveButton(
            icon: Icons.delete,
            label: "Delete project",
            confirmTitle: "Delete project?",
            confirmMessage: "Delete \"$project\", its $count "
                "${count == 1 ? "chat" : "chats"} and its shared workspace? "
                "This cannot be undone.",
            onConfirmed: () => deleteProject(context, ref, project, popToRoot: true),
          ),
        ],
      ),
    );
  }
}

class _CopyField extends StatelessWidget {
  const _CopyField({
    required this.label,
    required this.value,
    required this.snack,
  });

  final String label;
  final String value;
  final String snack;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Text(
        value,
        style: const TextStyle(fontFamily: "monospace"),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy),
        tooltip: "Copy",
        onPressed: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(snack)),
          );
        },
      ),
    );
  }
}