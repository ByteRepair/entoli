/// Which palette the app draws, or the system's own choice. Declaration order
/// is the order the settings page offers them in.
///
/// A mirror of material's `ThemeMode` rather than the thing itself: nothing in
/// `domain/` takes a material dependency, and a persisted name should not be
/// pinned to a framework enum's. `ui/theme.dart` maps one to the other.
enum AppTheme {
  system("System"),
  light("Light"),
  dark("Dark");

  const AppTheme(this.label);

  final String label;
}
