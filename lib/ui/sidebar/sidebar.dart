import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/builtin_project.dart";
import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../data/sync/sync_hub.dart" show RemoteChatEntry;
import "../../providers.dart";
import "../chat/chat_controller.dart";
import "../memory/memory_page.dart";
import "../profile/profile_page.dart";
import "../settings/settings_page.dart";
import "../widgets/anchored_menu.dart";
import "../widgets/nav_drawer.dart";
import "../widgets/dialogs.dart";
import "../widgets/nothing.dart";
import "../workspace/workspace_page.dart";
import "chat_groups.dart";
import "project_settings_page.dart";

/// Which chat the pane is showing, or null for the new-chat screen. **Null is
/// a screen rather than a chat to be made**: nothing is written until there is
/// something to say — see "Nothing selected is a new chat".
class SelectedChatId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;

  /// Make a chat in the project being shown and select it. **The one place a
  /// chat is created from the UI** — a method here rather than a function
  /// beside the widgets because not every caller has a `WidgetRef`.
  ///
  /// [meta] is the settings it should run its first turn under, for a screen
  /// that offered them before there was a chat to write them on. Null is a
  /// chat that could not be made, which is already logged.
  Future<String?> create({ChatMeta? meta}) async {
    try {
      final chat = await ref.read(chatRepositoryProvider).createChat(
            project: ref.read(selectedProjectProvider),
            meta: meta,
          );
      // A new chat is this device's, so the sidebar comes back from whatever
      // paired device it was reading.
      ref.read(selectedRemoteProvider.notifier).select(null);
      state = chat.state.id;
      ref.invalidate(chatListProvider);
      return chat.state.id;
    } catch (e) {
      logFailure("chat", "could not start a chat", e);
      return null;
    }
  }
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

/// A project on a paired device, as the switcher names one. Device *and*
/// project together, because `work` on a laptop and `work` on a phone are
/// different directories that happen to share a name — there is nothing to
/// gain by folding them together and a conversation to lose by it.
///
/// A record, for the value equality a map key and a `Notifier` state both
/// want. `project` null is that device's default one, the same as it is here.
typedef RemoteScope = ({String deviceId, String? project});

class SelectedRemote extends Notifier<RemoteScope?> {
  @override
  RemoteScope? build() => null;

  void select(RemoteScope? scope) => state = scope;
}

/// Which paired device's project the sidebar is listing, or null for one of
/// this device's own. Separate from [selectedProjectProvider] because they
/// answer different questions: this one is what is being *read*, and that one
/// is where new work goes — and new work never goes on somebody else's device.
final selectedRemoteProvider =
    NotifierProvider<SelectedRemote, RemoteScope?>(SelectedRemote.new);

void openChat(BuildContext context, WidgetRef ref, String chatId) {
  ref.read(selectedChatIdProvider.notifier).select(chatId);
  closeNavDrawer(context);
}

/// Switch to a project. A chat of the one being left is not in the list any
/// more, so keeping it selected would leave the pane showing something the
/// sidebar denies — and dropping it is also what starts a chat in the project
/// just picked. The switcher, the empty chat's badges and deleting a project
/// are all this.
void selectProject(WidgetRef ref, String? project) {
  ref.read(selectedProjectProvider.notifier).select(project);
  ref.read(selectedRemoteProvider.notifier).select(null);
  ref.read(selectedChatIdProvider.notifier).select(null);
}

/// Switch to a project on a paired device. The local project is left where it
/// was: it is where the next new chat goes, and coming back from a remote
/// should land where the user was, not wherever they were reading.
void selectRemote(WidgetRef ref, RemoteScope scope) {
  ref.read(selectedRemoteProvider.notifier).select(scope);
  ref.read(selectedChatIdProvider.notifier).select(null);
}

/// Go to the new-chat screen, with the drawer it was pressed in closed — the
/// sidebar's button and the assistant gesture. Nothing is created: the screen
/// makes a chat when the first thing is said in it.
void openNewChat(BuildContext context, WidgetRef ref) {
  ref.read(selectedChatIdProvider.notifier).select(null);
  // A new chat is this device's, so the sidebar comes back from whatever
  // paired device it was reading — the alternative is a list that denies the
  // screen now in front of the user.
  ref.read(selectedRemoteProvider.notifier).select(null);
  closeNavDrawer(context);
}

/// Start a chat and say the first thing in it. The new-chat screen's composer
/// is the one caller: it holds the text, the files and the settings until
/// there is a chat to put them in, and this is that moment. False is a chat
/// that could not be made, so that the caller can put back what it cleared.
///
/// The turn is deliberately not awaited — it runs for as long as the model
/// takes, and the page has to arrive on the message rather than after the
/// reply. Nothing waits on the controller having read the chat back either:
/// `send` waits on that itself, which is what [ChatController] owes anything
/// that drives a turn it has only just built.
Future<bool> startChatWith(
  WidgetRef ref,
  String text, {
  List<Attachment> attachments = const [],
  ChatMeta? meta,
}) async {
  final id = await ref.read(selectedChatIdProvider.notifier).create(meta: meta);
  if (id == null) return false;
  unawaited(ref
      .read(chatControllerProvider(id).notifier)
      .send(text, attachments: attachments));
  return true;
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

  /// What the slot beside the switcher holds for [project]. The default
  /// project has no settings page, so its workspace and its memories; a
  /// built-in the halves its spec says it has, plus a settings gear where its
  /// spec says it has a page worth opening; a user's project its settings
  /// page. The gear visibility is one predicate across every kind — see
  /// `projectHasSettingsPage`.
  List<Widget> _projectButtons(
      BuildContext context, WidgetRef ref, String? project) {
    final spec = builtinProjectOf(project);
    Widget workspace() => IconButton(
          icon: const Icon(Icons.folder_outlined),
          tooltip: "${projectLabel(project)} workspace",
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => WorkspacePage(
                root: ref
                    .read(appConfigProvider)
                    .projectWorkspaceDir(project: project),
                title: "${projectLabel(project)} workspace",
              ),
            ),
          ),
        );
    // The app's own store: what the default project shows beside its workspace
    // in place of a settings page, and what a built-in with [MemoryPolicy.app]
    // shows for the same reason.
    Widget memories() => IconButton(
          icon: const Icon(Icons.psychology_outlined),
          tooltip: "Memories",
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MemoryPage(
                dir: ref.read(appConfigProvider).memoryDir(),
                title: "Memories",
              ),
            ),
          ),
        );
    Widget settingsGear() => IconButton(
          icon: const Icon(Icons.settings),
          tooltip: "Project settings",
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ProjectSettingsPage(project: project!),
            ),
          ),
        );
    if (project == null) return [workspace(), memories()];
    return [
      if (spec?.sharedWorkspace ?? true) workspace(),
      if (spec == null || spec.memory != MemoryPolicy.off) memories(),
      if (projectHasSettingsPage(project)) settingsGear(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(selectedProjectProvider);
    final remote = ref.watch(selectedRemoteProvider);
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
                  ..._projectButtons(context, ref, project),
                ],
              ),
            ),
            Expanded(
              child: remote != null
                  ? _RemoteChatList(scope: remote, query: _query, search: _search)
                  : _LocalChatList(
                      project: project, query: _query, search: _search),
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
                    onPressed: () => openNewChat(context, ref),
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

const _noMatch = "No chat's title matches that.";

/// This device's chats in the project being shown. Its own widget so that
/// [chatListProvider] — which re-reads every chat's `state.json` when it is
/// invalidated, and every local turn invalidates it — is watched only while
/// this is on screen, rather than behind a paired device's list as well.
class _LocalChatList extends ConsumerWidget {
  const _LocalChatList({
    required this.project,
    required this.query,
    required this.search,
  });

  final String? project;
  final ValueNotifier<String> query;
  final TextEditingController search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(chatListProvider).when(
          data: (all) {
            // Expired chats are hidden here and deleted by the sweep; showing
            // one in the list that is about to vanish reads as a deletion on
            // the next refresh.
            final chats = all
                .where((c) => c.project == project && !c.isExpired())
                .toList();
            if (chats.isEmpty) {
              return const Nothing("No chats in this project yet.");
            }
            return Column(
              children: [
                _SearchField(controller: search, query: query),
                Expanded(child: _ChatList(chats: chats, query: query)),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text("Error: $e")),
        );
  }
}

/// One paired device's project, listed. Read-only by nature — the home device
/// owns the log — so the rows carry none of a local chat's menu: no pin,
/// rename, move or delete, which would all write to a disk this device does
/// not have. Nor any date grouping: a mirror answers to no date this sidebar
/// could place it under.
///
/// A gone connection keeps the rows. The snapshot is still readable, and each
/// one says the device is offline.
class _RemoteChatList extends ConsumerWidget {
  const _RemoteChatList({
    required this.scope,
    required this.query,
    required this.search,
  });

  final RemoteScope scope;
  final ValueNotifier<String> query;
  final TextEditingController search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chats = ref.watch(remoteChatsProvider)
        .where((entry) =>
            entry.deviceId == scope.deviceId &&
            entry.state.project == scope.project)
        .toList()
      ..sort((a, b) => b.state.updatedAt.compareTo(a.state.updatedAt));
    if (chats.isEmpty) {
      return const Nothing("Nothing mirrored from this device yet.");
    }
    return Column(
      children: [
        _SearchField(controller: search, query: query),
        Expanded(
          child: ValueListenableBuilder<String>(
            valueListenable: query,
            builder: (context, text, _) {
              final needle = searchNeedle(text);
              final matching = chats
                  .where((entry) => titleMatches(entry.state, needle))
                  .toList();
              if (matching.isEmpty) {
                return const Nothing(_noMatch);
              }
              return ListView.builder(
                itemCount: matching.length,
                itemBuilder: (context, i) {
                  final entry = matching[i];
                  // Per row, so tapping one rebuilds the two tiles that
                  // changed rather than re-filtering and re-sorting the list.
                  return Consumer(
                    builder: (context, ref, _) => _ChatTile(
                      chat: entry.state,
                      mutable: false,
                      selected: ref.watch(selectedChatIdProvider
                          .select((id) => id == entry.chatId)),
                      subtitle: entry.online
                          ? null
                          : Text("offline",
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.error)),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
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
        if (found.isEmpty) return const Nothing(_noMatch);
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
  const _ChatTile({
    required this.chat,
    required this.selected,
    this.mutable = true,
    this.subtitle,
  });

  final ChatState chat;
  final bool selected;

  /// False for a mirror: the home device owns the log, so there is nothing
  /// here that could pin, rename, move or delete it — and no local TTL for
  /// the hourglass to be about.
  final bool mutable;

  final Widget? subtitle;

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
        subtitle: subtitle,
        onTap: () => openChat(context, ref, chat.id),
        trailing: !mutable
            ? null
            : Row(
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
              case "pin":
                await _setPinned(ref, true);
              case "unpin":
                await _setPinned(ref, false);
              case "rename":
                await _rename(context, ref);
              case "move":
                await _move(context, ref);
              case "delete":
                await _delete(context, ref);
            }
          },
          itemBuilder: (context) => [
            if (chat.pinned)
              const PopupMenuItem(value: "unpin", child: Text("Unpin"))
            else
              const PopupMenuItem(value: "pin", child: Text("Pin")),
            const PopupMenuItem(value: "rename", child: Text("Rename")),
            const PopupMenuItem(value: "move", child: Text("Move to project…")),
            const PopupMenuItem(value: "delete", child: Text("Delete")),
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
    await ref.read(chatRepositoryProvider).retitle(chat.id, title);
    if (selected) {
      ref.read(chatControllerProvider(chat.id).notifier).applyTitle(title);
    }
    ref.invalidate(chatListProvider);
  }

  /// Pinning ends a temporary chat, which the title bar of the open one says —
  /// so the write is handed to its controller, or the bar keeps counting down
  /// to an expiry that is no longer there. Only where this chat is the open
  /// one: reading the notifier for any other builds a controller, and loads a
  /// conversation nobody is looking at.
  Future<void> _setPinned(WidgetRef ref, bool pinned) async {
    final repo = ref.read(chatRepositoryProvider);
    final written =
        await (pinned ? repo.pinChat(chat.id, chat) : repo.unpinChat(chat.id, chat));
    if (selected) {
      ref.read(chatControllerProvider(chat.id).notifier).applyState(written);
    }
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
    // The open controller holds the chat it read when it was built — project
    // included — so it is disposed and re-read from where the chat now is.
    // Without this, the open page keeps composing against the old project.
    if (ref.exists(chatControllerProvider(chat.id))) {
      ref.invalidate(chatControllerProvider(chat.id));
    }
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
/// How a project on a paired device is read out. Its default project is the
/// device's name alone — the local default has no name either, and inventing
/// one here would be the only place in the app that gives it one.
String _remoteLabel(String deviceName, String? project) =>
    project == null ? deviceName : "$deviceName · ${projectLabel(project)}";

/// Every project that has a mirrored chat in it, one entry each, device
/// first. A device with nothing mirrored has no projects to offer — the
/// welcome is what says a project exists at all.
List<({RemoteScope scope, String label})> _remoteEntries(
    List<RemoteChatEntry> remotes) {
  final byScope = <RemoteScope, String>{};
  for (final entry in remotes) {
    byScope[(deviceId: entry.deviceId, project: entry.state.project)] ??=
        entry.deviceName;
  }
  final entries = [
    for (final scope in byScope.keys)
      (scope: scope, label: _remoteLabel(byScope[scope]!, scope.project)),
  ];
  entries.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return entries;
}

/// The button's own text: the scope being read, named. A `String`, so
/// `select` suppresses the rebuild when a mirrored chat merely changed.
String _scopeLabel(
    List<RemoteChatEntry> remotes, RemoteScope? remote, String? project) {
  if (remote == null) return projectLabel(project);
  for (final entry in remotes) {
    if (entry.deviceId == remote.deviceId &&
        entry.state.project == remote.project) {
      return _remoteLabel(entry.deviceName, remote.project);
    }
  }
  return projectLabel(project);
}

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
    final remote = ref.watch(selectedRemoteProvider);
    final project = ref.watch(selectedProjectProvider);
    // Watched rather than read when the menu opens: it is a `FutureProvider`,
    // so nothing loads it until something watches, and a menu that read it on
    // the way up got an empty list every time.
    final projects = ref.watch(projectListProvider).value ?? const <String>[];
    // The label alone, not the list behind it: that is only wanted when the
    // menu opens, and watching it redrew this button on every state diff from
    // every mirrored chat. A `String` comes back, so `select` compares it.
    final label = remote == null
        ? projectLabel(project)
        : ref.watch(remoteChatsProvider
            .select((chats) => _scopeLabel(chats, remote, project)));
    return Align(
      alignment: Alignment.centerLeft,
      // The button's own context, which is what the menu is anchored under.
      child: Builder(
        builder: (context) => TextButton.icon(
          iconAlignment: IconAlignment.end,
          icon: const Icon(Icons.arrow_drop_down),
          label: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          onPressed: () => _open(context, ref, projects),
        ),
      ),
    );
  }

  /// One row of the menu. The check column's geometry is here once rather
  /// than at each list that has rows in it.
  PopupMenuItem<VoidCallback> _row(
          {required bool checked,
          required String label,
          IconData? icon,
          required VoidCallback pick}) =>
      PopupMenuItem(
        value: pick,
        child: Row(
          children: [
            Icon(Icons.check,
                size: 18, color: checked ? null : Colors.transparent),
            const SizedBox(width: 12),
            // A built-in project's icon sits beside the check; a user project
            // or a remote entry reserves the slot so the labels all align.
            if (icon != null)
              Icon(icon, size: 18)
            else
              const SizedBox(width: 18),
            const SizedBox(width: 12),
            Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );

  Future<void> _open(
      BuildContext context, WidgetRef ref, List<String> projects) async {
    final selected = ref.read(selectedProjectProvider);
    final remote = ref.read(selectedRemoteProvider);
    final remotes = _remoteEntries(ref.read(remoteChatsProvider));
    final chosen = await showAnchoredMenu<VoidCallback>(context, [
      for (final project in everyProject(projects))
        _row(
          checked: remote == null && project == selected,
          label: projectLabel(project),
          icon: projectIcon(project),
          pick: () => selectProject(ref, project),
        ),
      if (remotes.isNotEmpty) const PopupMenuDivider(),
      for (final entry in remotes)
        _row(
          checked: entry.scope == remote,
          label: entry.label,
          pick: () => selectRemote(ref, entry.scope),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: () => _create(context, ref),
        child: const Text("New project…"),
      ),
      // A built-in project cannot be deleted, so it is not offered one.
      if (selected != null && isProjectName(selected))
        PopupMenuItem(
          value: () => _delete(context, ref, selected),
          child: const Text("Delete project…"),
        ),
    ]);
    if (context.mounted) chosen?.call();
  }
}
