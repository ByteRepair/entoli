import "dart:convert";

/// What the native shell draws, one concern at a time, and what it sends
/// back. The shell is SwiftUI around the one Flutter view on iOS and macOS
/// with Liquid Glass on; it holds no state of its own past what a snapshot
/// last said, and does nothing but send an [ShellIntent]. Everything here is
/// plain data with a `toMap`, the Swift's `Codable` mirror of it reading the
/// same keys. See "Liquid Glass" in `lib/ui/AGENTS.md`.
///
/// A snapshot is sent only when its map has changed, compared as JSON, since
/// most are rebuilt on every frame a turn streams.
sealed class ShellSnapshot {
  const ShellSnapshot();

  /// Which of the Swift's models it fills, and the key it travels under.
  String get concern;

  Map<String, Object?> toMap();

  String encode() => jsonEncode(toMap());
}

/// The window around everything: whether a Flutter page covers the
/// conversation — the native chrome steps aside for it — whether the sidebar
/// is shown, and which appearance the app wears, which may not be the
/// system's.
class WindowSnapshot extends ShellSnapshot {
  const WindowSnapshot({
    required this.covered,
    required this.sidebarShown,
    required this.appearance,
  });

  /// A page is pushed over the conversation: Settings, a chat's settings, a
  /// drawer's page. A dialog is not; it draws over the Flutter view alone.
  final bool covered;
  final bool sidebarShown;

  /// `light`, `dark`, or null for the system's.
  final String? appearance;

  @override
  String get concern => "window";

  @override
  Map<String, Object?> toMap() => {
    "covered": covered,
    "sidebarShown": sidebarShown,
    "appearance": appearance,
  };
}

/// What the user did in the shell: [name] says what, [args] the rest.
/// Decoded from the map Swift sends; one with a name nothing answers is
/// dropped where it is handled.
class ShellIntent {
  const ShellIntent(this.name, [this.args = const {}]);

  factory ShellIntent.fromMap(Map<Object?, Object?> map) => ShellIntent(
    map["name"]! as String,
    (map["args"] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
        const {},
  );

  final String name;
  final Map<String, Object?> args;

  String string(String key) => args[key]! as String;
  String? maybeString(String key) => args[key] as String?;
  bool flag(String key) => args[key] as bool? ?? false;
  int integer(String key) => (args[key]! as num).toInt();
}

/// A project as the switcher lists it, and as a chat's Move offers it.
/// [device] and [project] are its `ProjectRef`, which an intent hands back.
class ProjectChoice {
  const ProjectChoice({
    required this.device,
    required this.project,
    required this.label,
    required this.symbol,
    this.omada = false,
    this.count = 0,
    this.busy = false,
  });

  final String? device;
  final String? project;
  final String label;

  /// An SF Symbol's name.
  final String symbol;

  /// Drawn italic, as the Flutter app draws an Omada project's name.
  final bool omada;
  final int count;

  /// One of its chats is running.
  final bool busy;

  Map<String, Object?> toMap() => {
    "device": device,
    "project": project,
    "label": label,
    "symbol": symbol,
    "omada": omada,
    "count": count,
    "busy": busy,
  };
}

/// One chat's row.
class SidebarRow {
  const SidebarRow({
    required this.id,
    required this.title,
    this.pinned = false,
    this.busy = false,
    this.temporary = false,
    this.offline = false,
    this.mutable = true,
    this.remote = false,
  });

  final String id;
  final String title;
  final bool pinned;

  /// A turn runs in it, or its browser tab is open.
  final bool busy;

  /// It will expire: the hourglass.
  final bool temporary;

  /// A mirror whose home device is away.
  final bool offline;

  /// Its menu is on offer: false for a mirror whose device is away.
  final bool mutable;

  /// A mirror, whose projects are its home device's, so it has no Move.
  final bool remote;

  Map<String, Object?> toMap() => {
    "id": id,
    "title": title,
    "pinned": pinned,
    "busy": busy,
    "temporary": temporary,
    "offline": offline,
    "mutable": mutable,
    "remote": remote,
  };
}

/// The rows under one heading; a paired device's list is one group with no
/// heading, a mirror answering to no date this sidebar could place it under.
class SidebarGroup {
  const SidebarGroup(this.heading, this.rows);

  final String heading;
  final List<SidebarRow> rows;

  Map<String, Object?> toMap() => {
    "heading": heading,
    "rows": [for (final row in rows) row.toMap()],
  };
}

/// The sidebar: the project being shown and the pages it has beside its
/// chats, its chats under their headings as the search leaves them, and every
/// project for the switcher.
class SidebarSnapshot extends ShellSnapshot {
  const SidebarSnapshot({
    required this.project,
    required this.pages,
    required this.groups,
    required this.selected,
    required this.query,
    required this.empty,
    required this.projects,
    required this.devices,
    required this.moveTargets,
    required this.omadaByDefault,
  });

  final ProjectChoice project;

  /// Of `workspace`, `memories` and `projectSettings`, the ones it has.
  final List<String> pages;
  final List<SidebarGroup> groups;
  final String? selected;

  /// What the search field holds: Dart's, so switching project clears it.
  final String query;

  /// What to say where there are no rows, null where there are.
  final String? empty;

  /// This device's projects, the default and the built-ins first.
  final List<ProjectChoice> projects;

  /// The paired devices' projects.
  final List<ProjectChoice> devices;

  /// Where a local chat can be moved to.
  final List<ProjectChoice> moveTargets;

  /// What the new-project sheet's Omada switch starts at.
  final bool omadaByDefault;

  @override
  String get concern => "sidebar";

  @override
  Map<String, Object?> toMap() => {
    "project": project.toMap(),
    "pages": pages,
    "groups": [for (final group in groups) group.toMap()],
    "selected": selected,
    "query": query,
    "empty": empty,
    "projects": [for (final p in projects) p.toMap()],
    "devices": [for (final p in devices) p.toMap()],
    "moveTargets": [for (final p in moveTargets) p.toMap()],
    "omadaByDefault": omadaByDefault,
  };
}
