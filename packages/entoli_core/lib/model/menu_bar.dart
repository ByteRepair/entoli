/// A platform's own menu bar, which draws menus it is sent as data and says
/// which item was picked. macOS's and iPadOS's, bound in `main`; every other
/// platform has none.
abstract interface class MenuBarHost {
  /// The whole bar, replacing what was there.
  void show(List<MenuBarMenu> menus);

  /// Told the id of the item picked; null stops listening.
  set onPicked(void Function(String id)? picked);
}

/// What a menu is to the platform: its own app, File, View and Help menus,
/// which the app's items join, or a menu of the app's own.
enum MenuBarRole { app, file, view, help, own }

/// One menu: its items in groups, a separator between each.
class MenuBarMenu {
  const MenuBarMenu({
    required this.title,
    required this.role,
    this.groups = const [],
  });

  final String title;
  final MenuBarRole role;
  final List<List<MenuBarItem>> groups;
}

/// One item: [key] is the character typed with the chord key, lower case,
/// and [symbol] the SF Symbol drawn beside the title.
class MenuBarItem {
  const MenuBarItem({
    required this.id,
    required this.title,
    this.key,
    this.shift = false,
    this.alt = false,
    this.enabled = true,
    this.symbol,
  });

  final String id;
  final String title;
  final String? key;
  final bool shift;
  final bool alt;
  final bool enabled;
  final String? symbol;
}
