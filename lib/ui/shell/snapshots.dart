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
