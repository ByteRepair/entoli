import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/chat_search.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../selection.dart";
import "../sidebar/project_palette.dart"
    show chatsByRecency, createProject, isUserProject;
import "../sidebar/remote_projects.dart";
import "shell_outbox.dart";
import "shell_routes.dart";
import "shell_sidebar.dart" show projectSymbol;
import "snapshots.dart";

/// Whether the native palette is open, what is typed in it, and which opening
/// this is.
typedef PaletteState = ({bool open, String query, int serial});

class ShellPalette extends Notifier<PaletteState> {
  @override
  PaletteState build() => (open: false, query: "", serial: 0);

  /// Open it empty: Cmd+K, or the menu's Switch Project.
  void open() => state = (open: true, query: "", serial: state.serial + 1);

  void close() => state = (open: false, query: "", serial: state.serial);

  void search(String query) =>
      state = (open: state.open, query: query, serial: state.serial);
}

final shellPaletteProvider = NotifierProvider<ShellPalette, PaletteState>(
  ShellPalette.new,
);

const _remoteSymbol = "laptopcomputer.and.iphone";

/// Sends the [PaletteSnapshot] while the palette is open: `ProjectPalette`'s
/// list, read and narrowed the same way — the default project and the
/// built-ins, the user's projects, other devices', then every chat, running
/// ones first — or, with something typed, the projects and chats it matches.
class PalettePublisher extends ConsumerWidget {
  const PalettePublisher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(shellPaletteProvider);
    final outbox = ref.read(shellOutboxProvider);
    if (!palette.open) {
      outbox.post(PaletteSnapshot(open: false, serial: palette.serial));
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<Set<String>>(
      valueListenable: ref.watch(busyChatsProvider),
      builder: (context, running, _) {
        outbox.post(_snapshot(ref, palette, running));
        return const SizedBox.shrink();
      },
    );
  }

  PaletteSnapshot _snapshot(
    WidgetRef ref,
    PaletteState palette,
    Set<String> running,
  ) {
    final selected = ref.watch(selectedProjectProvider);
    final selectedChat = ref.watch(selectedChatIdProvider);
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    final chats = (ref.watch(chatListProvider).value ?? const <ChatState>[])
        .where((c) => !c.isExpired())
        .toList();
    final remotes = remoteEntries(
      ref.watch(remoteChatsProvider),
      ref.watch(deviceProjectsProvider),
      ref.watch(syncPeersProvider),
    );
    final counts = <String?, int>{};
    final busy = <String?>{};
    for (final chat in chats) {
      counts[chat.project] = (counts[chat.project] ?? 0) + 1;
      if (running.contains(chat.id)) busy.add(chat.project);
    }

    PaletteItem local(String? p) => PaletteItem(
      id: "p::${p ?? ""}",
      label: projectLabel(p),
      project: p,
      symbol: projectSymbol(p),
      omada: ref.watch(omadaOnProvider(p)),
      trailing: "${counts[p] ?? 0}",
      busy: busy.contains(p),
      current: selected == localProject(p),
    );
    PaletteItem mirrored(RemoteEntry e) => PaletteItem(
      id: "p:${e.scope.device}:${e.scope.project ?? ""}",
      label: e.label,
      device: e.scope.device,
      project: e.scope.project,
      symbol: _remoteSymbol,
      omada: e.omada,
      trailing: "${e.count}",
      current: e.scope == selected,
    );

    final needle = searchNeedle(palette.query);
    final every = everyProject(named);
    final sections = <({String heading, List<PaletteItem> items})>[];
    if (needle.isEmpty) {
      sections
        ..add((
          heading: "",
          items: [
            for (final p in every.where((p) => !isUserProject(p))) local(p),
          ],
        ))
        ..add((
          heading: "",
          items: [for (final p in every.where(isUserProject)) local(p)],
        ));
      if (remotes.isNotEmpty) {
        sections.add((
          heading: "Other Devices",
          items: [for (final e in remotes) mirrored(e)],
        ));
      }
    } else {
      final projects = [
        for (final p in every)
          if (projectLabel(p).toLowerCase().contains(needle)) local(p),
        for (final e in remotes)
          if (e.label.toLowerCase().contains(needle)) mirrored(e),
      ];
      if (projects.isNotEmpty) {
        sections.add((heading: "Projects", items: projects));
      }
    }
    final found = chatsByRecency(chatsMatching(chats, palette.query), running);
    if (found.isNotEmpty) {
      sections.add((
        heading: "Chats",
        items: [
          for (final chat in found)
            PaletteItem(
              id: "c:${chat.id}",
              label: chat.title.orUntitled,
              chat: chat.id,
              trailing: projectLabel(chat.project),
              busy: running.contains(chat.id),
              current: chat.id == selectedChat,
            ),
        ],
      ));
    }
    return PaletteSnapshot(
      open: true,
      query: palette.query,
      sections: [
        for (final s in sections)
          if (s.items.isNotEmpty) s,
      ],
      serial: palette.serial,
      omadaByDefault: ref.watch(
        appSettingsProvider.select((s) => s.omadaByDefault),
      ),
    );
  }
}

/// Runs what the native palette sends, in [context] under the Navigator.
/// Answers what the Swift waits on: an error to show, or null.
Future<Object?> runPaletteIntent(
  BuildContext context,
  WidgetRef ref,
  String name,
  Map<String, Object?> args,
) async {
  final palette = ref.read(shellPaletteProvider.notifier);
  switch (name) {
    case "search":
      palette.search(args["query"] as String? ?? "");
    case "close":
      palette.close();
    case "pickProject":
      palette.close();
      await toConversation(context, ref.read(shellRoutesProvider));
      selectProject(ref, (
        device: args["device"] as String?,
        project: args["project"] as String?,
      ));
    case "pickChat":
      palette.close();
      final id = args["chat"]! as String;
      final chat = ref
          .read(chatListProvider)
          .value
          ?.where((c) => c.id == id)
          .firstOrNull;
      if (chat == null) return null;
      await toConversation(context, ref.read(shellRoutesProvider));
      // Into its project first: the sidebar lists one, and would otherwise
      // deny the chat on screen.
      ref.read(selectedChatIdProvider.notifier).reveal(chat);
    case "createProject":
      final dir = projectNameFrom(args["name"] as String? ?? "");
      if (dir == null) return "That is not a name a project can have.";
      try {
        if (!context.mounted) return null;
        await createProject((
          name: dir,
          description: args["description"] as String? ?? "",
          omada: args["omada"] == true,
        ), ref.read(selectedProjectProvider).device)(context, ref);
      } catch (_) {
        return "The project could not be created.";
      }
      palette.close();
  }
  return null;
}
