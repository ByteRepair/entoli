/// Declaration order is the order the settings page offers them in.
enum AppIcon {
  cookie(
    label: "Cookie",
    description: "A shell prompt in Material 3's scalloped shape.",
  ),
  prompt(label: "Prompt", description: "The same prompt in a speech bubble.");

  const AppIcon({required this.label, required this.description});

  final String label;
  final String description;

  String get asset => "assets/icons/$name.svg";
}

/// Changes the icon the launcher shows. Android only; elsewhere [available] is
/// false and [use] does nothing.
abstract interface class LauncherIcons {
  bool get available;

  Future<void> use(AppIcon icon);
}
