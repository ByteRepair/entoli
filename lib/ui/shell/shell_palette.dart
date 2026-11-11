import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../selection.dart";
import "../sidebar/project_palette.dart" show paletteListing;
import "../sidebar/remote_projects.dart";
import "../app_routes.dart";
import "glyphs.dart";

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

/// The [PaletteSnapshot]: while the palette is open, `ProjectPalette`'s
/// list, [paletteListing] — the default project and the built-ins, the
/// user's projects, other devices', then every chat, running ones first — or,
/// with something typed, the projects and chats it matches. `ShellPublisher`
/// sends it.
final paletteSnapshotProvider = Provider<PaletteSnapshot>((ref) {
  final palette = ref.watch(shellPaletteProvider);
  return palette.open
      ? _paletteSnapshot(ref, palette)
      : PaletteSnapshot(open: false, serial: palette.serial);
});

PaletteSnapshot _paletteSnapshot(Ref ref, PaletteState palette) {
  final running = ref.watch(busyChatIdsProvider);
  final selected = ref.watch(selectedProjectProvider);
  final selectedChat = ref.watch(selectedChatIdProvider);
  final chats = (ref.watch(chatListProvider).value ?? const <ChatState>[])
      .where((c) => !c.isExpired())
      .toList();
  final (:counts, :busy) = projectCounts(chats, running);

  PaletteItem local(String? p) => PaletteItem(
    id: "p::${p ?? ""}",
    label: projectLabel(p),
    project: p,
    glyph: projectShellGlyph(p),
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
    glyph: Glyph.remote,
    omada: e.omada,
    trailing: "${e.count}",
    current: e.scope == selected,
  );

  final listing = paletteListing(
    named: ref.watch(projectListProvider).value ?? const <String>[],
    chats: chats,
    remotes: remoteEntries(
      ref.watch(remoteChatsProvider),
      ref.watch(deviceProjectsProvider),
      ref.watch(syncPeersProvider),
    ),
    query: palette.query,
    running: running,
  );
  final sections = [
    if (!listing.searching) ...[
      PaletteSection(
        heading: "",
        items: [for (final p in listing.projects) local(p)],
      ),
      PaletteSection(
        heading: "",
        items: [for (final p in listing.mine) local(p)],
      ),
      PaletteSection(
        heading: "Other Devices",
        items: [for (final e in listing.devices) mirrored(e)],
      ),
    ] else
      PaletteSection(
        heading: "Projects",
        items: [
          for (final p in listing.projects) local(p),
          for (final e in listing.devices) mirrored(e),
        ],
      ),
    PaletteSection(
      heading: "Chats",
      items: [
        for (final chat in listing.chats)
          PaletteItem(
            id: "c:${chat.id}",
            label: chat.title.orUntitled,
            chat: chat.id,
            trailing: projectLabel(chat.project),
            busy: running.contains(chat.id),
            current: chat.id == selectedChat,
          ),
      ],
    ),
  ];
  return PaletteSnapshot(
    open: true,
    query: palette.query,
    sections: [
      for (final s in sections)
        if (s.items.isNotEmpty) s,
    ],
    serial: palette.serial,
  );
}

/// The app's own, under a name [PaletteRunner]'s methods do not hide.
const _selectProject = selectProject;

/// Runs what the native palette sends, in [context] under the Navigator. A
/// project made from the palette is the sidebar's `createProject`.
class PaletteRunner implements PaletteIntents {
  PaletteRunner(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  ShellPalette get _palette => ref.read(shellPaletteProvider.notifier);

  @override
  void search(String query) => _palette.search(query);

  @override
  void close() => _palette.close();

  @override
  Future<void> pickProject(String? device, String? project) async {
    _palette.close();
    if (!await toConversation(context, ref.read(appRoutesProvider))) return;
    _selectProject(ref, (device: device, project: project));
  }

  @override
  Future<void> pickChat(String id) async {
    _palette.close();
    final chat = ref
        .read(chatListProvider)
        .value
        ?.where((c) => c.id == id)
        .firstOrNull;
    if (chat == null) return;
    if (!context.mounted ||
        !await toConversation(context, ref.read(appRoutesProvider))) {
      return;
    }
    // Into its project first: the sidebar lists one, and would otherwise
    // deny the chat on screen.
    ref.read(selectedChatIdProvider.notifier).reveal(chat);
  }
}
