import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/chat_search.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../chat_actions.dart";
import "../marketplace/marketplace_page.dart";
import "../profile/profile_page.dart";
import "../project_actions.dart";
import "../selection.dart";
import "../settings/settings_category.dart";
import "../sidebar/chat_groups.dart";
import "../sidebar/project_palette.dart";
import "../sidebar/remote_projects.dart";
import "shell_outbox.dart";
import "../app_routes.dart";

/// What the native sidebar's search field holds. Dart's rather than the
/// field's, so the one rule the Flutter sidebar searches by is the one here,
/// and switching project clears it.
class ShellSearch extends Notifier<String> {
  @override
  String build() => "";

  void set(String query) => state = query;
}

final shellSearchProvider = NotifierProvider<ShellSearch, String>(
  ShellSearch.new,
);

/// An SF Symbol for [project], the one [projectGlyph] draws in Material.
String projectSymbol(String? project) {
  final icon = projectIcon(project);
  if (icon == Icons.visibility_off) return "eye.slash";
  if (icon == Icons.groups) return "person.3";
  if (icon == Icons.verified_user) return "checkmark.shield";
  return project == null ? "house" : "folder";
}

/// A paired device's project, which has no symbol of its own.
const remoteSymbol = "laptopcomputer.and.iphone";

/// Sends the [SidebarSnapshot]: what `Sidebar` draws, read the same way.
/// Everything is read in [build], the publisher's own, so each of it rebuilds
/// it: a provider watched from a builder beneath can be missed, and the list
/// with it — the chats arriving a frame after the first snapshot went out
/// empty.
class SidebarPublisher extends ConsumerWidget {
  const SidebarPublisher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The list the query was written against has just been replaced.
    ref.listen(
      selectedProjectProvider,
      (_, _) => ref.read(shellSearchProvider.notifier).set(""),
    );
    ref.read(shellOutboxProvider).sidebar(_snapshot(ref));
    return const SizedBox.shrink();
  }

  SidebarSnapshot _snapshot(WidgetRef ref) {
    final busy = ref.watch(busyChatIdsProvider);
    final selected = ref.watch(selectedProjectProvider);
    final query = ref.watch(shellSearchProvider);
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    final chats = (ref.watch(chatListProvider).value ?? const <ChatState>[])
        .where((c) => !c.isExpired())
        .toList();
    final remotes = ref.watch(remoteChatsProvider);
    final peers = ref.watch(syncPeersProvider);
    final devices = remoteEntries(
      remotes,
      ref.watch(deviceProjectsProvider),
      peers,
    );

    final (:counts, busy: _) = projectCounts(chats, busy);
    ProjectChoice local(String? p) => ProjectChoice(
      device: null,
      project: p,
      label: projectLabel(p),
      symbol: projectSymbol(p),
      omada: ref.watch(omadaOnProvider(p)),
      count: counts[p] ?? 0,
    );
    final projects = [for (final p in everyProject(named)) local(p)];
    final mirrored = [
      for (final e in devices)
        ProjectChoice(
          device: e.scope.device,
          project: e.scope.project,
          label: e.label,
          symbol: remoteSymbol,
          omada: e.omada,
          count: e.count,
        ),
    ];

    final remote = selected.device != null;
    final ProjectChoice current;
    final List<SidebarGroup> groups;
    final String? empty;
    if (remote) {
      current =
          mirrored
              .where(
                (p) =>
                    p.device == selected.device &&
                    p.project == selected.project,
              )
              .firstOrNull ??
          ProjectChoice(
            device: selected.device,
            project: selected.project,
            label: remoteLabel(
              peers[selected.device]?.name ?? selected.device!,
              selected.project,
            ),
            symbol: remoteSymbol,
          );
      final mine =
          remotes
              .where(
                (e) =>
                    e.deviceId == selected.device &&
                    e.state.project == selected.project,
              )
              .toList()
            ..sort((a, b) => b.state.updatedAt.compareTo(a.state.updatedAt));
      final needle = searchNeedle(query);
      final rows = [
        for (final e in mine)
          if (titleMatches(e.state, needle))
            SidebarRow(
              id: e.chatId,
              title: e.state.title.orUntitled,
              pinned: e.state.pinned,
              offline: !e.online,
              mutable: e.online,
              remote: true,
            ),
      ];
      groups = [if (rows.isNotEmpty) SidebarGroup(heading: "", rows: rows)];
      empty = mine.isEmpty
          ? "Nothing mirrored from this device yet."
          : rows.isEmpty
          ? "No chat's title matches that."
          : null;
    } else {
      current = local(selected.project);
      final mine = chats.where((c) => c.project == selected.project).toList();
      final found = chatsMatching(mine, query);
      groups = [
        for (final group in groupChatsByDate(found, now: DateTime.now()))
          SidebarGroup(
            heading: group.heading,
            rows: [
              for (final chat in group.chats)
                SidebarRow(
                  id: chat.id,
                  title: chat.title.orUntitled,
                  pinned: chat.pinned,
                  busy: busy.contains(chat.id),
                  temporary: chat.tempTtlExpiresAt != null,
                ),
            ],
          ),
      ];
      empty = mine.isEmpty
          ? "No chats in this project yet."
          : found.isEmpty
          ? "No chat's title matches that."
          : null;
    }

    return SidebarSnapshot(
      project: current,
      pages: [
        if (projectHasWorkspace(selected)) ShellPage.workspace,
        if (projectHasMemories(selected)) ShellPage.memories,
        if (projectHasSettings(selected)) ShellPage.projectSettings,
      ],
      groups: groups,
      selected: ref.watch(selectedChatIdProvider),
      query: query,
      empty: empty,
      projects: projects,
      devices: mirrored,
      omadaByDefault: ref.watch(
        appSettingsProvider.select((s) => s.omadaByDefault),
      ),
    );
  }
}

/// The chat [id] names, wherever it is: this device's, or a mirror.
ChatState? _chatOf(WidgetRef ref, String id) =>
    ref.read(chatListProvider).value?.where((c) => c.id == id).firstOrNull ??
    ref
        .read(remoteChatsProvider)
        .where((e) => e.chatId == id)
        .firstOrNull
        ?.state;

/// The app's own, under names [SidebarRunner]'s methods do not hide.
const _selectProject = selectProject;
const _createProject = createProject;

/// Runs what the native sidebar sends, in [context] under the Navigator: the
/// intents sent under no surface's name.
class SidebarRunner implements SidebarIntents {
  SidebarRunner(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  ChatState? _chat(String id) => _chatOf(ref, id);

  /// Close the pages over the conversation, for what changes what the detail
  /// shows. Answers whether it got there: a page asking first is left
  /// asking, and nothing changes under it.
  Future<bool> _toConversation() async {
    final reached = await toConversation(context, ref.read(appRoutesProvider));
    return reached && context.mounted;
  }

  @override
  Future<void> search(String query) async =>
      ref.read(shellSearchProvider.notifier).set(query);

  @override
  Future<void> openChat(String id) async {
    if (!await _toConversation()) return;
    ref.read(selectedChatIdProvider.notifier).select(id);
  }

  @override
  Future<void> newChat() async {
    if (!await _toConversation()) return;
    ref.read(selectedChatIdProvider.notifier).select(null);
  }

  @override
  Future<void> selectProject(String? device, String? project) async {
    if (!await _toConversation()) return;
    _selectProject(ref, (device: device, project: project));
  }

  @override
  Future<void> pin(String id, bool pinned) async {
    if (_chat(id) case final chat?) {
      await ref.read(chatEditsProvider).setPinned(chat, pinned);
    }
  }

  @override
  Future<void> rename(String id, String title) async {
    if (_chat(id) case final chat?) {
      await ref.read(chatEditsProvider).retitle(chat, title);
    }
  }

  @override
  Future<void> move(String id, String? project) async {
    if (!await _toConversation()) return;
    if (_chat(id) case final chat? when project != chat.project) {
      await ref.read(chatEditsProvider).move(chat, project);
      _selectProject(ref, localProject(project));
    }
  }

  @override
  Future<void> delete(String id) async {
    if (_chat(id) case final chat?) {
      await ref.read(chatEditsProvider).delete(chat);
    }
  }

  @override
  Future<String?> createProject(
    String name,
    String description,
    bool omada,
  ) async {
    final named = projectNameFrom(name);
    if (named == null) return "That is not a name a project can have.";
    try {
      await _createProject((
        name: named,
        description: description,
        omada: omada,
      ), ref.read(selectedProjectProvider).device)(context, ref);
    } catch (e) {
      logFailure("shell", "createProject", e);
      return "The project could not be created.";
    }
    return null;
  }

  @override
  Future<void> openPage(ShellPage page) async {
    final at = ref.read(selectedProjectProvider);
    switch (page) {
      case ShellPage.workspace:
        openProjectWorkspace(context, ref, at);
      case ShellPage.memories:
        openProjectMemories(context, at);
      case ShellPage.projectSettings:
        openProjectSettings(context, at);
      case ShellPage.settings:
        openSettings(context);
      case ShellPage.profile:
        openProfile(context);
      case ShellPage.marketplace:
        openMarketplace(context);
    }
  }
}
