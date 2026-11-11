import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/chat_search.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../../app/chat_edits.dart";
import "../marketplace/marketplace_page.dart";
import "../profile/profile_page.dart";
import "../project_actions.dart";
import "../selection.dart";
import "../settings/settings_category.dart";
import "../../app/chat_groups.dart";
import "../sidebar/project_palette.dart";
import "../../app/remote_projects.dart";
import "../app_routes.dart";
import "glyphs.dart";

/// What the native sidebar's search field holds. Dart's rather than the
/// field's, so the one rule the Flutter sidebar searches by is the one here,
/// and switching project clears it.
class ShellSearch extends Notifier<String> {
  /// Empty, and empty again whenever the project changes: the list the query
  /// was written against has just been replaced.
  @override
  String build() {
    ref.watch(selectedProjectProvider);
    return "";
  }

  void set(String query) => state = query;
}

final shellSearchProvider = NotifierProvider<ShellSearch, String>(
  ShellSearch.new,
);

/// What `Sidebar` draws, read the same way, as the native sidebar's
/// snapshot: `ShellPublisher` sends it.
final sidebarSnapshotProvider = Provider<SidebarSnapshot>(_sidebarSnapshot);

SidebarSnapshot _sidebarSnapshot(Ref ref) {
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
    project: p,
    label: projectLabel(p),
    glyph: projectShellGlyph(p),
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
        glyph: Glyph.remote,
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
                  p.device == selected.device && p.project == selected.project,
            )
            .firstOrNull ??
        ProjectChoice(
          device: selected.device,
          project: selected.project,
          label: remoteLabel(
            peers[selected.device]?.name ?? selected.device!,
            selected.project,
          ),
          glyph: Glyph.remote,
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

const _createProject = createProject;

/// Runs what the native sidebar sends, in [context] under the Navigator: the
/// intents sent under no surface's name.
class SidebarRunner implements SidebarIntents {
  SidebarRunner(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  /// Run [then] once the pages over the conversation are closed, for what
  /// changes what the detail shows. A page asking first is left asking, and
  /// nothing changes under it.
  Future<void> _closing(FutureOr<void> Function() then) async {
    final reached = await toConversation(context, ref.read(appRoutesProvider));
    if (reached && context.mounted) await then();
  }

  /// [edit] the chat [id] names, wherever it is: this device's, or a mirror.
  Future<void> _edit(String id, Future<void> Function(ChatState) edit) async {
    final chat =
        ref
            .read(chatListProvider)
            .value
            ?.where((c) => c.id == id)
            .firstOrNull ??
        ref
            .read(remoteChatsProvider)
            .where((e) => e.chatId == id)
            .firstOrNull
            ?.state;
    if (chat != null) await edit(chat);
  }

  ChatEdits get _edits => ref.read(chatEditsProvider);

  @override
  void search(String query) =>
      ref.read(shellSearchProvider.notifier).set(query);

  @override
  Future<void> openChat(String id) =>
      _closing(() => ref.read(selectedChatIdProvider.notifier).select(id));

  @override
  Future<void> newChat() =>
      _closing(() => ref.read(selectedChatIdProvider.notifier).select(null));

  @override
  Future<void> selectProject(String? device, String? project) => _closing(
    () => ref.read(selectedProjectProvider.notifier).switchTo((
      device: device,
      project: project,
    )),
  );

  @override
  Future<void> pin(String id, bool pinned) =>
      _edit(id, (chat) => _edits.setPinned(chat, pinned));

  @override
  Future<void> rename(String id, String title) =>
      _edit(id, (chat) => _edits.retitle(chat, title));

  @override
  Future<void> delete(String id) => _edit(id, _edits.delete);

  @override
  Future<void> move(String id, String? project) => _closing(
    () => _edit(id, (chat) async {
      if (project == chat.project) return;
      await _edits.move(chat, project);
      ref
          .read(selectedProjectProvider.notifier)
          .switchTo(localProject(project));
    }),
  );

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
      return null;
    } catch (e) {
      logFailure("shell", "createProject", e);
      return "The project could not be created.";
    }
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
