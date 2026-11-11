import "app_items.dart";

/// The menu bar, where the platform has one: macOS's, and iPadOS's (whose
/// keys an iPhone answers). Shown once at launch whichever frontend is on
/// screen; the frontend on screen is what answers a pick.
abstract interface class AppMenus {
  /// Whether this platform has a menu bar, which then holds the keys of
  /// every item in it.
  bool get available;

  /// [menus] as the bar shows them now, each item titled and greyed by
  /// [title] and [enabled].
  void show(
    List<AppMenu> menus, {
    required String Function(AppItem item) title,
    required bool Function(AppItem item) enabled,
  });

  /// Told the item picked; null stops listening.
  set onPicked(void Function(AppItem item)? picked);
}

/// No menu bar: every platform but the Apple ones.
class NoAppMenus implements AppMenus {
  const NoAppMenus();

  @override
  bool get available => false;

  @override
  void show(
    List<AppMenu> menus, {
    required String Function(AppItem item) title,
    required bool Function(AppItem item) enabled,
  }) {}

  @override
  set onPicked(void Function(AppItem item)? picked) {}
}
