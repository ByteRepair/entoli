import "package:entoli_core/model/menu_bar.dart";

import "app_items.dart";

/// The menu bar, where the platform has one: macOS's, and iPadOS's (whose
/// keys an iPhone answers). Shown once at launch.
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

/// SF Symbols for the items standing in for one of the platform's own, which
/// wear its icon: Settings is in the place of the Settings scene's item.
const _symbols = <AppItem, String>{Destination.settings: "gearshape"};

/// The app's menus on a platform's own [MenuBarHost].
class HostAppMenus implements AppMenus {
  HostAppMenus(this._bar);

  final MenuBarHost _bar;

  @override
  bool get available => true;

  @override
  set onPicked(void Function(AppItem item)? picked) =>
      _bar.onPicked = picked == null
      ? null
      : (id) {
          if (appItemNamed(id) case final item?) picked(item);
        };

  @override
  void show(
    List<AppMenu> menus, {
    required String Function(AppItem item) title,
    required bool Function(AppItem item) enabled,
  }) => _bar.show([
    for (final menu in menus)
      MenuBarMenu(
        title: menu.title,
        groups: [
          for (final group in menu.groups)
            [
              for (final item in group)
                MenuBarItem(
                  id: item.id,
                  title: title(item),
                  key: item.key?.char,
                  shift: item.key?.shift ?? false,
                  alt: item.key?.alt ?? false,
                  enabled: enabled(item),
                  symbol: _symbols[item],
                ),
            ],
        ],
        role: menu.role,
      ),
  ]);
}
