import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../chat/chat_controller.dart";
import "../profile/profile_page.dart";
import "../settings/settings_page.dart";
import "../widgets/anchored_menu.dart";
import "../widgets/dialogs.dart";
import "project_settings_page.dart";

class SelectedChatId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedChatIdProvider = NotifierProvider<SelectedChatId, String?>(SelectedChatId.new);

/// Which project the sidebar is showing, and where a new chat goes. Null is
/// the default project, which is what the app opens in.
class SelectedProject extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? project) => state = project;
}

final selectedProjectProvider =
    NotifierProvider<SelectedProject, String?>(SelectedProject.new);

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key});

  /// Selecting a chat should reveal it. On narrow layouts the sidebar is a
  /// drawer sitting over the chat, so it has to get out of the way.
  void _open(BuildContext context, WidgetRef ref, String chatId) {
    ref.read(selectedChatIdProvider.notifier).select(chatId);
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isDrawerOpen ?? false) scaffold!.closeDrawer();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(chatListProvider);
    final selectedId = ref.watch(selectedChatIdProvider);
    final project = ref.watch(selectedProjectProvider);
    // Material, not Scaffold: the shell's Scaffold owns the drawer, and an
    // inner one would shadow it.
    return Material(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(child: _ProjectMenu()),
                  if (project != null)
                    IconButton(
                      icon: const Icon(Icons.settings),
                      tooltip: "Project settings",
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ProjectSettingsPage(project: project),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: async.when(
                data: (all) {
                  final chats = all.where((c) => c.project == project).toList();
                  return ListView.builder(
                    itemCount: chats.length,
                    itemBuilder: (context, i) {
                      final c = chats[i];
                      final selected = selectedId == c.id;
                      return ListTile(
                        selected: selected,
                        title: Text(c.title.orUntitled),
                        subtitle: Text(_formatTimestamp(c.updatedAt)),
                        onTap: () => _open(context, ref, c.id),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert),
                          onSelected: (value) async {
                            switch (value) {
                              case "rename":
                                final title = await promptForText(
                                  context,
                                  title: "Rename chat",
                                  initial: c.title,
                                  hint: "Chat title",
                                  confirmLabel: "Rename",
                                );
                                if (title == null) return;
                                await ref.read(chatRepositoryProvider).retitle(c, title);
                                ref.read(chatControllerProvider(c.id).notifier).applyTitle(title);
                                ref.invalidate(chatListProvider);
                              case "move":
                                await _move(context, ref, c);
                              case "delete":
                                final confirmed = await confirm(
                                  context,
                                  title: "Delete chat?",
                                  message:
                                      "Delete \"${c.title.orUntitled}\"? This cannot be undone.",
                                  confirmLabel: "Delete",
                                  destructive: true,
                                );
                                if (!confirmed) return;
                                if (selected) ref.read(selectedChatIdProvider.notifier).select(null);
                                await ref.read(chatRepositoryProvider).deleteChat(c.id);
                                ref.invalidate(chatListProvider);
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: "rename", child: Text("Rename")),
                            PopupMenuItem(value: "move", child: Text("Move to project…")),
                            PopupMenuItem(value: "delete", child: Text("Delete")),
                          ],
                        ),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text("Error: $e")),
              ),
            ),
            const Divider(height: 1),
            Stack(
              alignment: Alignment.centerRight,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text("Profile"),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ProfilePage(project: null)),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.settings),
                      title: const Text("Settings"),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: FloatingActionButton(
                    heroTag: null,
                    tooltip: "New chat",
                    // Nothing is listed here yet: an empty chat is not on disk,
                    // and joins the list when its first message is saved.
                    onPressed: () async {
                      final chat =
                          await ref.read(chatRepositoryProvider).createChat(project: project);
                      if (context.mounted) _open(context, ref, chat.state.id);
                    },
                    child: const Icon(Icons.add),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// File a chat elsewhere and follow it: it has just left the list being
  /// shown, and a chat that vanished on being moved reads as a deletion.
  Future<void> _move(BuildContext context, WidgetRef ref, ChatState chat) async {
    final repo = ref.read(chatRepositoryProvider);
    final projects = await repo.listProjects();
    if (!context.mounted) return;
    final picked = await pickProject(
      context,
      projects: everyProject(projects),
      current: chat.project,
    );
    if (picked == null || picked.project == chat.project) return;
    await repo.moveChat(chat.id, picked.project);
    ref.read(selectedProjectProvider.notifier).select(picked.project);
    ref.invalidate(chatListProvider);
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _formatTimestamp(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_months[l.month - 1]} ${l.day}, ${two(l.hour)}:${two(l.minute)}';
  }
}

/// The project being shown, and everything that changes it. Its name is what
/// the chats and the shared workspace sit under on disk.
class _ProjectMenu extends ConsumerWidget {
  const _ProjectMenu();

  /// A chat of the project being left is not in the list any more, so keeping
  /// it selected would leave the pane showing something the sidebar denies.
  void _select(WidgetRef ref, String? project) {
    ref.read(selectedProjectProvider.notifier).select(project);
    ref.read(selectedChatIdProvider.notifier).select(null);
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final typed = await promptForText(
      context,
      title: "New project",
      initial: "",
      hint: "Project name",
      confirmLabel: "Create",
    );
    final name = typed == null ? null : projectNameFrom(typed);
    if (name == null) return;
    await ref.read(chatRepositoryProvider).createProject(name);
    ref.invalidate(projectListProvider);
    _select(ref, name);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String project) =>
      deleteProject(context, ref, project);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedProjectProvider);
    final projects = ref.watch(projectListProvider).value ?? const [];
    return Align(
      alignment: Alignment.centerLeft,
      // The button's own context, which is what the menu is anchored under.
      child: Builder(
        builder: (context) => TextButton.icon(
          iconAlignment: IconAlignment.end,
          icon: const Icon(Icons.arrow_drop_down),
          label: Text(
            projectLabel(selected),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          onPressed: () => _open(context, ref, selected, projects),
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    String? selected,
    List<String> projects,
  ) async {
    final chosen = await showAnchoredMenu<VoidCallback>(context, [
      for (final project in everyProject(projects))
        PopupMenuItem(
          value: () => _select(ref, project),
          child: Row(
            children: [
              Icon(
                Icons.check,
                size: 18,
                color: project == selected ? null : Colors.transparent,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(projectLabel(project), overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: () => _create(context, ref),
        child: const Text("New project…"),
      ),
      if (selected != null)
        PopupMenuItem(
          value: () => _delete(context, ref, selected),
          child: const Text("Delete project…"),
        ),
    ]);
    if (context.mounted) chosen?.call();
  }
}
