import "package:entoli_menu/entoli_menu.dart";

import "../../app/app_items.dart";
import "../../app/app_menus.dart";
import "../log.dart";

/// The menu bar on macOS and iPadOS: `entoli_menu`'s, sent whole and only
/// when what it says changed.
class NativeAppMenus implements AppMenus, NativeMenuPicks {
  NativeAppMenus() {
    NativeMenuPicks.setUp(this);
  }

  final NativeMenuBar _bar = NativeMenuBar();
  List<NativeMenu>? _shown;
  void Function(AppItem item)? _picked;

  @override
  bool get available => true;

  @override
  set onPicked(void Function(AppItem item)? picked) => _picked = picked;

  @override
  void picked(String id) {
    if (appItemNamed(id) case final item?) _picked?.call(item);
  }

  @override
  void show(
    List<AppMenu> menus, {
    required String Function(AppItem item) title,
    required bool Function(AppItem item) enabled,
  }) {
    final native = [
      for (final menu in menus)
        NativeMenu(
          title: menu.title,
          groups: [
            for (final group in menu.groups)
              [
                for (final item in group)
                  NativeMenuItem(
                    id: item.id,
                    title: title(item),
                    key: item.key?.char,
                    shift: item.key?.shift ?? false,
                    alt: item.key?.alt ?? false,
                    enabled: enabled(item),
                  ),
              ],
          ],
          system: [for (final item in menu.system) _system(item)],
        ),
    ];
    if (_same(native, _shown)) return;
    _shown = native;
    _bar.show(native).catchError((Object e) => logFailure("menu", "show: $e"));
  }

  static bool _same(List<NativeMenu> a, List<NativeMenu>? b) =>
      b != null &&
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

  static NativeSystemItem _system(SystemMenuItem item) => switch (item) {
    SystemMenuItem.services => NativeSystemItem.services,
    SystemMenuItem.hide => NativeSystemItem.hide,
    SystemMenuItem.hideOthers => NativeSystemItem.hideOthers,
    SystemMenuItem.showAll => NativeSystemItem.showAll,
    SystemMenuItem.quit => NativeSystemItem.quit,
    SystemMenuItem.toggleFullScreen => NativeSystemItem.toggleFullScreen,
    SystemMenuItem.minimize => NativeSystemItem.minimize,
    SystemMenuItem.zoom => NativeSystemItem.zoom,
    SystemMenuItem.arrangeInFront => NativeSystemItem.arrangeInFront,
  };
}
