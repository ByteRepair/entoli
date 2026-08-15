enum AppIcon {
  prompt(
    label: "Prompt",
    description: "A speech bubble around a shell prompt.",
  ),
  cookie(
    label: "Cookie",
    description: "The same prompt in Material 3's scalloped shape.",
  );

  const AppIcon({required this.label, required this.description});

  final String label;
  final String description;

  String get asset => "assets/icons/$name.svg";

  /// An unknown name is a file written by a later build, so it falls back
  /// rather than failing the whole settings load.
  static AppIcon fromName(String? name) =>
      values.firstWhere((icon) => icon.name == name, orElse: () => prompt);
}

/// Changes the icon the launcher shows. Android only; elsewhere [available] is
/// false and [use] does nothing.
abstract interface class LauncherIcons {
  bool get available;

  Future<void> use(AppIcon icon);
}
