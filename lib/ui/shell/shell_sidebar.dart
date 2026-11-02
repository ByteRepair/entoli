import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

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
import "shell_routes.dart";
import "snapshots.dart";

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

const _remoteSymbol = "laptopcomputer.and.iphone";

/// Sends the [SidebarSnapshot]: what `Sidebar` draws, read the same way.
class SidebarPublisher extends ConsumerWidget {
  const SidebarPublisher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The list the query was written against has just been replaced.
    ref.listen(
      selectedProjectProvider,
      (_, _) => ref.read(shellSearchProvider.notifier).set(""),
    );
    return ValueListenableBuilder<Set<String>>(
      valueListenable: ref.watch(busyChatsProvider),
      builder: (context, busy, _) {
        ref.read(shellOutboxProvider).post(_snapshot(ref, busy));
        return const SizedBox.shrink();
      },
    );
  }

  SidebarSnapshot _snapshot(WidgetRef ref, Set<String> busy) {
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

    final counts = <String?, int>{};
    final running = <String?>{};
    for (final chat in chats) {
      counts[chat.project] = (counts[chat.project] ?? 0) + 1;
      if (busy.contains(chat.id)) running.add(chat.project);
    }
    ProjectChoice local(String? p) => ProjectChoice(
      device: null,
      project: p,
      label: projectLabel(p),
      symbol: projectSymbol(p),
      omada: ref.watch(omadaOnProvider(p)),
      count: counts[p] ?? 0,
      busy: running.contains(p),
    );
    final projects = [for (final p in everyProject(named)) local(p)];
    final mirrored = [
      for (final e in devices)
        ProjectChoice(
          device: e.scope.device,
          project: e.scope.project,
          label: e.label,
          symbol: _remoteSymbol,
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
          mirrored.where((p) => p.project == selected.project).firstOrNull ??
          ProjectChoice(
            device: selected.device,
            project: selected.project,
            label: remoteLabel(
              peers[selected.device]?.name ?? selected.device!,
              selected.project,
            ),
            symbol: _remoteSymbol,
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
      groups = [if (rows.isNotEmpty) SidebarGroup("", rows)];
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
          SidebarGroup(group.heading, [
            for (final chat in group.chats)
              SidebarRow(
                id: chat.id,
                title: chat.title.orUntitled,
                pinned: chat.pinned,
                busy: busy.contains(chat.id),
                temporary: chat.tempTtlExpiresAt != null,
              ),
          ]),
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
        if (projectHasWorkspace(selected)) "workspace",
        if (projectHasMemories(selected)) "memories",
        if (projectHasSettings(selected)) "projectSettings",
      ],
      groups: groups,
      selected: ref.watch(selectedChatIdProvider),
      query: query,
      empty: empty,
      projects: projects,
      devices: mirrored,
      moveTargets: projects,
      omadaByDefault: ref.watch(
        appSettingsProvider.select((s) => s.omadaByDefault),
      ),
    );
  }
}

/// The chat [id] names, wherever it is: this device's, or a mirror.
ChatState? _chat(WidgetRef ref, String id) =>
    ref.read(chatListProvider).value?.where((c) => c.id == id).firstOrNull ??
    ref
        .read(remoteChatsProvider)
        .where((e) => e.chatId == id)
        .firstOrNull
        ?.state;

ProjectRef _projectOf(ShellIntent intent) => (
  device: intent.maybeString("device"),
  project: intent.maybeString("project"),
);

/// Runs what the native sidebar sends, in [context] under the Navigator.
/// Answers whether it was the sidebar's, and with what the Swift waits on:
/// an error to show, or null.
Future<({bool handled, Object? answer})> runSidebarIntent(
  BuildContext context,
  WidgetRef ref,
  ShellIntent intent,
) async {
  final edits = ref.read(chatEditsProvider);
  ChatState? chat() => _chat(ref, intent.string("id"));
  // What changes what the detail shows closes the pages over it first.
  const navigates = {"openChat", "newChat", "selectProject", "move"};
  if (navigates.contains(intent.name)) {
    await toConversation(context, ref.read(shellRoutesProvider));
    if (!context.mounted) return (handled: true, answer: null);
  }
  switch (intent.name) {
    case "search":
      ref.read(shellSearchProvider.notifier).set(intent.string("query"));
    case "openChat":
      ref.read(selectedChatIdProvider.notifier).select(intent.string("id"));
    case "newChat":
      ref.read(selectedChatIdProvider.notifier).select(null);
    case "selectProject":
      selectProject(ref, _projectOf(intent));
    case "pin":
      if (chat() case final chat?) {
        await edits.setPinned(chat, intent.flag("pinned"));
      }
    case "rename":
      if (chat() case final chat?) {
        await edits.retitle(chat, intent.string("title"));
      }
    case "move":
      if (chat() case final chat?) {
        final project = intent.maybeString("project");
        if (project != chat.project) {
          await edits.move(chat, project);
          selectProject(ref, localProject(project));
        }
      }
    case "delete":
      if (chat() case final chat?) await edits.delete(chat);
    case "createProject":
      final name = projectNameFrom(intent.string("name"));
      if (name == null) {
        return (
          handled: true,
          answer: "That is not a name a project can have.",
        );
      }
      try {
        await createProject((
          name: name,
          description: intent.maybeString("description") ?? "",
          omada: intent.flag("omada"),
        ), ref.read(selectedProjectProvider).device)(context, ref);
      } catch (_) {
        return (handled: true, answer: "The project could not be created.");
      }
    case "openPage":
      final at = ref.read(selectedProjectProvider);
      switch (intent.string("page")) {
        case "workspace":
          openProjectWorkspace(context, ref, at);
        case "memories":
          openProjectMemories(context, at);
        case "projectSettings":
          openProjectSettings(context, at);
        case "settings":
          openSettings(context);
        case "profile":
          openProfile(context);
        case "marketplace":
          openMarketplace(context);
      }
    default:
      return (handled: false, answer: null);
  }
  return (handled: true, answer: null);
}
