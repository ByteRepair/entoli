import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "../memory/memory_page.dart";
import "../profile/profile_page.dart";
import "../fonts.dart";
import "../widgets/destructive_button.dart";
import "../widgets/dialogs.dart";
import "../widgets/resettable_field.dart";
import "../workspace/workspace_page.dart";
import "sidebar.dart";

/// Delete a project, its chats, and its shared workspace. Confirms first
/// (unless [confirm] is false — the settings page's `DestructiveButton` has
/// already asked), deselects the project and its chats, and invalidates the
/// lists so the UI reflects the deletion. Shared by the sidebar's project
/// menu and the project settings page so the invalidations agree.
Future<void> deleteProject(
  BuildContext context,
  WidgetRef ref,
  String project, {
  bool popToRoot = false,
  bool confirm = true,
}) async {
  if (confirm) {
    final count = (ref.read(chatListProvider).value ?? const [])
        .where((c) => c.project == project)
        .length;
    if (!await _confirmDeleteProject(context, project, count)) return;
  }
  await ref.read(chatRepositoryProvider).deleteProject(project);
  selectProject(ref, null);
  // The other reference to a project that no longer exists. Both ends resolve a
  // dangling name to the default project anyway, but leaving it written down
  // means the next save writes it back — and recreating a project of that name
  // would silently re-arm the setting.
  final settings = ref.read(appSettingsProvider);
  if (settings.assistantProject == project) {
    await ref.read(appSettingsProvider.notifier).setAssistantProject(null);
  }
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
    final chats = ref.watch(chatListProvider).value ?? const [];
    final count = chats.where((c) => c.project == project).length;
    final path = ref.watch(appConfigProvider).projectDir(project: project);

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
          WorkspaceTile(
            root: ref.watch(appConfigProvider).projectWorkspaceDir(project: project),
            title: "Project workspace",
          ),
          const Divider(),
          _UseProjectMemoryRow(project: project),
          MemoryTile(
            dir: ref.watch(appConfigProvider).memoryDir(project: project),
            title: "Project memories",
          ),
          const Divider(),
          ListTile(
            title: const Text("Chats"),
            trailing: Text("$count"),
          ),
          const Divider(),
          _ProfileRow(project: project),
          const Divider(),
          _TempChatTtlRow(project: project),
          const Divider(),
          DestructiveButton(
            icon: Icons.delete,
            label: "Delete project",
            confirmTitle: "Delete project?",
            confirmMessage: "Delete \"$project\", its $count "
                "${count == 1 ? "chat" : "chats"} and its shared workspace? "
                "This cannot be undone.",
            onConfirmed: () => deleteProject(context, ref, project,
                popToRoot: true, confirm: false),
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
        style: const TextStyle(fontFamily: monoFamily),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy),
        tooltip: "Copy",
        onPressed: () => copyToClipboard(context, value, said: snack),
      ),
    );
  }
}

/// Shows whether this project overrides the app-level profile, and opens the
/// editor. "Default" means the project inherits the app profile.
class _ProfileRow extends ConsumerWidget {
  const _ProfileRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(project));
    final hasOverride = settings.profile != null && !settings.profile!.isEmpty;
    return ListTile(
      leading: const Icon(Icons.person_outline),
      title: const Text("Profile"),
      subtitle: Text(hasOverride ? "Customized" : "Default (inherited)"),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProfilePage(project: project)),
      ),
    );
  }
}

/// Whether this project keeps its own memory store or shares the default
/// project's. Off, its chats read and write the default project's memories.
class _UseProjectMemoryRow extends ConsumerWidget {
  const _UseProjectMemoryRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(projectSettingsProvider(project).select((s) => s.useProjectMemory));
    return SwitchListTile(
      title: const Text("Project memory"),
      subtitle: const Text(
          "Off, this project's chats share the default project's memories."),
      value: on,
      onChanged: (value) =>
          ref.read(projectSettingsProvider(project).notifier).setUseProjectMemory(value),
    );
  }
}

/// The project's temporary-chat TTL override. Null means inherit the app
/// default; the inherited value is named in the Default entry.
class _TempChatTtlRow extends ConsumerWidget {
  const _TempChatTtlRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(project));
    final appTtl = ref.watch(appSettingsProvider).tempChatTtl;
    return InheritableDropdown<TempChatTtl>(
      label: "Temporary chats",
      value: settings.tempChatTtl,
      inherited: appTtl.label,
      options: tempChatTtlLabels,
      onChanged: (v) =>
          ref.read(projectSettingsProvider(project).notifier).setTempChatTtl(v),
    );
  }
}