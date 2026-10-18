import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/builtin_project.dart";
import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../data/sync/peers.dart" show PeerState;
import "../../data/sync/sync_hub.dart" show RemoteChatEntry;
import "../../providers.dart";
import "../chat/chat_controller.dart";
import "../memory/memory_page.dart";
import "../marketplace/marketplace_page.dart";
import "../profile/profile_page.dart";
import "../settings/settings_page.dart";
import "../widgets/nav_drawer.dart";
import "../widgets/dialogs.dart";
import "../widgets/nothing.dart";
import "../workspace/workspace_page.dart";
import "chat_groups.dart";
import "project_palette.dart";
import "project_settings_page.dart";

/// The sidebar's width where it is docked beside the chat pane.
const sidebarWidth = 300.0;

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
      final at = ref.read(selectedProjectProvider);
      if (at.device != null) return null;
      final chat = await ref.read(chatRepositoryProvider).createChat(
            project: at.project,
            meta: meta,
          );
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

/// Which project the sidebar is showing, on whichever device, and where a new
/// chat goes. This device's default project is what the app opens in.
class SelectedProject extends Notifier<ProjectRef> {
  @override
  ProjectRef build() => localProject(null);

  void select(ProjectRef project) => state = project;
}

final selectedProjectProvider =
    NotifierProvider<SelectedProject, ProjectRef>(SelectedProject.new);

void openChat(BuildContext context, WidgetRef ref, String chatId) {
  ref.read(selectedChatIdProvider.notifier).select(chatId);
  closeNavDrawer(context);
}

/// Switch to a project. A chat of the one being left is not in the list any
/// more, so keeping it selected would leave the pane showing something the
/// sidebar denies — and dropping it is also what starts a chat in the project
/// just picked. The switcher, the empty chat's badges and deleting a project
/// are all this.
void selectProject(WidgetRef ref, ProjectRef project) {
  ref.read(selectedProjectProvider.notifier).select(project);
  ref.read(selectedChatIdProvider.notifier).select(null);
}

/// Go to the new-chat screen, with the drawer it was pressed in closed — the
/// sidebar's button and the assistant gesture. Nothing is created: the screen
/// makes a chat when the first thing is said in it.
void openNewChat(BuildContext context, WidgetRef ref) {
  ref.read(selectedChatIdProvider.notifier).select(null);
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
    final selected = ref.watch(selectedProjectProvider);
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
                  if (selected.device == null)
                    ..._projectButtons(context, ref, selected.project)
                  else if (projectHasSettingsPage(selected.project))
                    IconButton(
                      icon: const Icon(Icons.settings),
                      tooltip: "Project settings",
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ProjectSettingsPage(
                            project: selected.project!, device: selected.device),
                      )),
                    ),
                ],
              ),
            ),
            Expanded(
              child: selected.device != null
                  ? _RemoteChatList(scope: selected, query: _query, search: _search)
                  : _LocalChatList(
                      project: selected.project, query: _query, search: _search),
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
                      leading: const Icon(Icons.storefront_outlined),
                      title: const Text("Marketplace"),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const MarketplacePage()),
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

  final ProjectRef scope;
  final ValueNotifier<String> query;
  final TextEditingController search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chats = ref.watch(remoteChatsProvider)
        .where((entry) =>
            entry.deviceId == scope.device &&
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
                      mutable: entry.online,
                      remote: true,
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
    this.remote = false,
    this.subtitle,
  });

  final ChatState chat;
  final bool selected;

  /// False for a mirror whose home device is away: its writes have nowhere
  /// to go until it is back.
  final bool mutable;

  /// A mirror: its writes go to the home device, and its projects are that
  /// device's, so there is nowhere here to move it to.
  final bool remote;

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
        contentPadding: const EdgeInsets.only(left: 12, right: 4),
        minLeadingWidth: 16,
        horizontalTitleGap: 8,
        // The slot is there whether or not a turn is, so the title does not
        // move each time one starts or ends.
        leading: SizedBox.square(
          dimension: 16,
          child: ValueListenableBuilder<Set<String>>(
            valueListenable: ref.watch(agentBackendProvider).runningTurns,
            builder: (context, running, _) => running.contains(chat.id)
                ? const CircularProgressIndicator(strokeWidth: 2)
                : const SizedBox.shrink(),
          ),
        ),
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
            if (!remote)
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
    if (selected && !remote) {
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
    if (selected && !remote) {
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
    ref.invalidate(chatControllerProvider(chat.id));
    ref.read(selectedProjectProvider.notifier).select(localProject(picked.project));
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

/// How a project on a paired device is read out. Its default project is the
/// device's name alone — the local default has no name either, and inventing
/// one here would be the only place in the app that gives it one.
String _remoteLabel(String deviceName, String? project) =>
    project == null ? deviceName : "$deviceName · ${projectLabel(project)}";

/// A project on a paired device, as the switcher lists it.
typedef RemoteEntry = ({ProjectRef scope, String label, bool omada, int count});

/// Every project of every paired device, one entry each, device first: what
/// the device last listed, whether or not anything of it is mirrored here.
List<RemoteEntry> remoteEntries(List<RemoteChatEntry> remotes,
    Map<String, List<String>> projects, Map<String, PeerState> peers) {
  final counts = <ProjectRef, int>{};
  final omada = <ProjectRef>{};
  for (final entry in remotes) {
    final ProjectRef scope = (device: entry.deviceId, project: entry.state.project);
    counts[scope] = (counts[scope] ?? 0) + 1;
    if (entry.omada) omada.add(scope);
  }
  final entries = [
    for (final MapEntry(key: device, value: named) in projects.entries)
      for (final project in everyProject(named))
        if ((device: device, project: project) case final ProjectRef scope)
          (
            scope: scope,
            label: _remoteLabel(peers[device]?.name ?? device, project),
            omada: omada.contains(scope),
            count: counts[scope] ?? 0,
          ),
  ];
  entries.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return entries;
}

/// The project being shown, and the way to the palette that changes it.
class _ProjectMenu extends ConsumerWidget {
  const _ProjectMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selected = ref.watch(selectedProjectProvider);
    final remote = selected.device != null;
    // The label alone, not the list behind it: watching the list redrew this
    // button on every state diff from every mirrored chat. A `String` comes
    // back, so `select` compares it.
    final label = !remote
        ? projectLabel(selected.project)
        : _remoteLabel(
            ref.watch(syncPeersProvider.select((peers) => peers[selected.device]?.name)) ??
                selected.device!,
            selected.project);
    final omada = !remote
        ? ref.watch(omadaOnProvider(selected.project))
        : ref.watch(remoteChatsProvider.select((chats) => chats.any((e) =>
            e.deviceId == selected.device &&
            e.state.project == selected.project &&
            e.omada)));
    return Tooltip(
      message: "Switch project",
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showProjectPalette(context, ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(!remote ? projectGlyph(selected.project) : remoteGlyph,
                  size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)
                      .merge(projectLabelStyle(omada)),
                ),
              ),
              Icon(Icons.unfold_more,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
