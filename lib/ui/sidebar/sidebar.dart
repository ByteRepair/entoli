import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../chat/chat_controller.dart";
import "../profile/profile_page.dart";
import "../settings/settings_page.dart";
import "../widgets/anchored_menu.dart";
import "../widgets/nav_drawer.dart";
import "../widgets/dialogs.dart";
import "chat_groups.dart";
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

void openChat(BuildContext context, WidgetRef ref, String chatId) {
  ref.read(selectedChatIdProvider.notifier).select(chatId);
  closeNavDrawer(context);
}

/// Switch to a project. A chat of the one being left is not in the list any
/// more, so keeping it selected would leave the pane showing something the
/// sidebar denies. The switcher, the empty pane's badges and deleting a project
/// are all this.
void selectProject(WidgetRef ref, String? project) {
  ref.read(selectedProjectProvider.notifier).select(project);
  ref.read(selectedChatIdProvider.notifier).select(null);
}

/// A new chat in the project being shown, opened. Nothing is listed here yet:
/// an empty chat is not on disk, and joins the list when its first message is
/// saved. The sidebar's button and the empty pane's are the same action.
Future<void> startChat(BuildContext context, WidgetRef ref) async {
  final project = ref.read(selectedProjectProvider);
  final chat = await ref.read(chatRepositoryProvider).createChat(project: project);
  if (context.mounted) openChat(context, ref, chat.state.id);
}

class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key});

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  final TextEditingController _search = TextEditingController();

  /// A notifier rather than `setState`: the list is what a keystroke changes,
  /// and the project switcher above it has no business rebuilding to answer one.
  ///
  /// Rather than listening to `_search` directly, which is a
  /// `ValueListenable<TextEditingValue>` and would do — but the value it
  /// carries is the text *and the caret*, so moving the caret in the field
  /// would rebuild and regroup the whole list. This holds the text alone, and
  /// so only fires when the text is what changed. Same reason `Composer` keeps
  /// `_canSend`.
  final ValueNotifier<String> _query = ValueNotifier("");

  @override
  void initState() {
    super.initState();
    _search.addListener(() => _query.value = _search.text);
  }

  @override
  void dispose() {
    _search.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(chatListProvider);
    final project = ref.watch(selectedProjectProvider);
    // The list the query was written against has just been replaced, the same
    // reason switching clears the selected chat. Kept, it would answer a
    // project the user has left with "nothing matches".
    ref.listen(selectedProjectProvider, (_, _) => _search.clear());
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
                   // Expired chats are hidden here and deleted by the sweep;
                   // showing one in the list that is about to vanish reads as a
                   // deletion on the next refresh.
                   final chats = all
                       .where((c) =>
                           c.project == project && !c.isExpired())
                       .toList();
                  if (chats.isEmpty) {
                    return const _Nothing("No chats in this project yet.");
                  }
                  return Column(
                    children: [
                      _SearchField(controller: _search, query: _query),
                      Expanded(child: _ChatList(chats: chats, query: _query)),
                    ],
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
                    onPressed: () => startChat(context, ref),
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

}

/// What the sidebar says where it would otherwise be blank: a project with no
/// chats in it, or a search nothing answered.
class _Nothing extends StatelessWidget {
  const _Nothing(this.said);

  final String said;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: Text(
          said,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.query});

  final TextEditingController controller;

  /// The same text the controller holds, listened to so the clear button comes
  /// and goes without the field itself being rebuilt from above.
  final ValueNotifier<String> query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: ValueListenableBuilder<String>(
        valueListenable: query,
        builder: (context, text, _) => TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            hintText: "Search chats",
            prefixIcon: const Icon(Icons.search, size: 20),
            prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            suffixIcon: text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: "Clear search",
                    onPressed: controller.clear,
                  ),
            suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// The chats of the project being shown, filtered by what is in the search
/// field and under a heading for the day, the week or the month they were last
/// touched in.
class _ChatList extends ConsumerWidget {
  const _ChatList({required this.chats, required this.query});

  final List<ChatState> chats;
  final ValueNotifier<String> query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedChatIdProvider);
    return ValueListenableBuilder<String>(
      valueListenable: query,
      builder: (context, text, _) {
        final found = chatsMatching(chats, text);
        if (found.isEmpty) return const _Nothing("No chat's title matches that.");
        // A sliver per group rather than one list over headings and chats
        // flattened together: the flat form has to say which of the two each
        // row is, and there is no shape for that which is not two nullable
        // fields of which exactly one is ever set.
        return CustomScrollView(
          slivers: [
            for (final group in groupChatsByDate(found, now: DateTime.now())) ...[
              SliverToBoxAdapter(child: _Heading(group.heading)),
              SliverList.builder(
                itemCount: group.chats.length,
                itemBuilder: (context, i) => _ChatTile(
                  chat: group.chats[i],
                  selected: group.chats[i].id == selectedId,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ChatTile extends ConsumerWidget {
  const _ChatTile({required this.chat, required this.selected});

  final ChatState chat;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        selected: selected,
        selectedColor: theme.colorScheme.onSecondaryContainer,
        selectedTileColor: theme.colorScheme.secondaryContainer,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        // The heading above says when, so the row is the title and nothing else.
        title: Text(chat.title.orUntitled, overflow: TextOverflow.ellipsis),
        onTap: () => openChat(context, ref, chat.id),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (chat.tempTtlExpiresAt != null)
              Icon(
                Icons.hourglass_empty,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) async {
            switch (value) {
              case "rename":
                await _rename(context, ref);
              case "move":
                await _move(context, ref);
              case "delete":
                await _delete(context, ref);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: "rename", child: Text("Rename")),
            PopupMenuItem(value: "move", child: Text("Move to project…")),
            PopupMenuItem(value: "delete", child: Text("Delete")),
          ],
        ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final title = await promptForText(
      context,
      title: "Rename chat",
      initial: chat.title,
      hint: "Chat title",
      confirmLabel: "Rename",
    );
    if (title == null) return;
    await ref.read(chatRepositoryProvider).retitle(chat, title);
    ref.read(chatControllerProvider(chat.id).notifier).applyTitle(title);
    ref.invalidate(chatListProvider);
  }

  /// File a chat elsewhere and follow it: it has just left the list being
  /// shown, and a chat that vanished on being moved reads as a deletion.
  Future<void> _move(BuildContext context, WidgetRef ref) async {
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

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirm(
      context,
      title: "Delete chat?",
      message: "Delete \"${chat.title.orUntitled}\"? This cannot be undone.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!confirmed) return;
    if (selected) ref.read(selectedChatIdProvider.notifier).select(null);
    await ref.read(chatRepositoryProvider).deleteChat(chat.id);
    ref.invalidate(chatListProvider);
  }
}

/// The project being shown, and everything that changes it. Its name is what
/// the chats and the shared workspace sit under on disk.
class _ProjectMenu extends ConsumerWidget {
  const _ProjectMenu();

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
    selectProject(ref, name);
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
          value: () => selectProject(ref, project),
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
