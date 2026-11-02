import "dart:async";

import "package:flutter/cupertino.dart" show CupertinoIcons;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/platform/form_factor.dart";
import "../../domain/chat_search.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../app_command.dart";
import "../chat_actions.dart";
import "../marketplace/marketplace_page.dart";
import "../profile/profile_page.dart";
import "../project_actions.dart";
import "../settings/settings_category.dart";
import "../selection.dart";
import "../widgets/nothing.dart";
import "../widgets/search_field.dart";
import "chat_groups.dart";
import "project_palette.dart";
import "remote_projects.dart";

/// The sidebar's width where it is docked beside the chat pane.
const sidebarWidth = 300.0;

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

  /// The buttons beside the switcher: the pages the project has beside its
  /// chats, which `project_actions.dart` says.
  List<Widget> _projectButtons(
    BuildContext context,
    WidgetRef ref,
    ProjectRef at,
  ) => [
    if (projectHasWorkspace(at))
      IconButton(
        icon: const Icon(Icons.folder_outlined),
        tooltip: "${projectLabel(at.project)} workspace",
        onPressed: () => openProjectWorkspace(context, ref, at),
      ),
    if (projectHasMemories(at))
      IconButton(
        icon: const Icon(Icons.psychology_outlined),
        tooltip: "Memories",
        onPressed: () => openProjectMemories(context, at),
      ),
    if (projectHasSettings(at))
      IconButton(
        icon: const Icon(Icons.settings),
        tooltip: "Project settings",
        onPressed: () => openProjectSettings(context, at),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedProjectProvider);
    final scheme = Theme.of(context).colorScheme;
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
                  ..._projectButtons(context, ref, selected),
                  // Apple's apps put compose at the top of the list it adds
                  // to, a plain glyph in the accent colour — Notes, Mail,
                  // Messages — rather than anything filled or floating.
                  if (isApple)
                    IconButton(
                      icon: const Icon(CupertinoIcons.square_pencil),
                      color: scheme.primary,
                      tooltip: "New chat",
                      onPressed: () => openNewChat(context, ref),
                    ),
                ],
              ),
            ),
            Expanded(
              child: selected.device != null
                  ? _RemoteChatList(
                      scope: selected,
                      query: _query,
                      search: _search,
                    )
                  : _LocalChatList(
                      project: selected.project,
                      query: _query,
                      search: _search,
                    ),
            ),
            // The menu bar holds the app's pages where it is always on screen,
            // and compose is in the header on Apple's platforms, which leaves
            // nothing at the bottom.
            if (!menuBarAlwaysShown) ...[
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
                        onTap: () => openProfile(context),
                      ),
                      ListTile(
                        leading: const Icon(Icons.storefront_outlined),
                        title: const Text("Marketplace"),
                        onTap: () => openMarketplace(context),
                      ),
                      ListTile(
                        leading: const Icon(Icons.settings),
                        title: const Text("Settings"),
                        onTap: () => openSettings(context),
                      ),
                    ],
                  ),
                  if (!isApple)
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
    return ref
        .watch(chatListProvider)
        .when(
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
                SearchField(controller: search, hint: "Search chats"),
                Expanded(
                  child: _ChatList(chats: chats, query: query),
                ),
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
    final chats =
        ref
            .watch(remoteChatsProvider)
            .where(
              (entry) =>
                  entry.deviceId == scope.device &&
                  entry.state.project == scope.project,
            )
            .toList()
          ..sort((a, b) => b.state.updatedAt.compareTo(a.state.updatedAt));
    if (chats.isEmpty) {
      return const Nothing("Nothing mirrored from this device yet.");
    }
    return Column(
      children: [
        SearchField(controller: search, hint: "Search chats"),
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
                      selected: ref.watch(
                        selectedChatIdProvider.select(
                          (id) => id == entry.chatId,
                        ),
                      ),
                      subtitle: entry.online
                          ? null
                          : Text(
                              "offline",
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
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
            for (final group in groupChatsByDate(
              found,
              now: DateTime.now(),
            )) ...[
              SliverToBoxAdapter(child: ListHeading(group.heading)),
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
      child: GestureDetector(
        onSecondaryTapUp: !mutable
            ? null
            : (details) => _contextMenu(context, ref, details.globalPosition),
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
              valueListenable: ref.watch(busyChatsProvider),
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
                    PopupMenuButton<AppCommand>(
                      icon: const Icon(Icons.more_vert),
                      onSelected: (command) =>
                          runOnChat(context, ref, chat, command),
                      itemBuilder: (_) => _items,
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// The row's menu, the same from the button and from a right-click: the
  /// chat commands, in the row's own shorter words, less Move for a mirror,
  /// whose projects are its home device's.
  List<PopupMenuEntry<AppCommand>> get _items => [
    for (final command in chatCommands)
      if (!(remote && command == AppCommand.moveChat))
        PopupMenuItem(
          value: command,
          child: Text(switch (command) {
            AppCommand.pinChat => chat.pinned ? "Unpin" : "Pin",
            AppCommand.renameChat => "Rename",
            AppCommand.moveChat => "Move to project…",
            _ => "Delete",
          }),
        ),
  ];

  Future<void> _contextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset at,
  ) async {
    final command = await showMenu<AppCommand>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: _items,
    );
    if (command != null && context.mounted) {
      await runOnChat(context, ref, chat, command);
    }
  }
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
        : remoteLabel(
            ref.watch(
                  syncPeersProvider.select(
                    (peers) => peers[selected.device]?.name,
                  ),
                ) ??
                selected.device!,
            selected.project,
          );
    final omada = !remote
        ? ref.watch(omadaOnProvider(selected.project))
        : ref.watch(
            remoteChatsProvider.select(
              (chats) => chats.any(
                (e) =>
                    e.deviceId == selected.device &&
                    e.state.project == selected.project &&
                    e.omada,
              ),
            ),
          );
    return Tooltip(
      message: "Switch project",
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showProjectPalette(context, ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(
                !remote ? projectGlyph(selected.project) : remoteGlyph,
                size: 22,
              ),
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
              Icon(
                Icons.unfold_more,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
