import "package:flutter/foundation.dart" show listEquals;
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
          role: switch (menu.role) {
            MenuRole.app => NativeMenuRole.app,
            MenuRole.file => NativeMenuRole.file,
            MenuRole.view => NativeMenuRole.view,
            MenuRole.help => NativeMenuRole.help,
            MenuRole.own => NativeMenuRole.own,
          },
        ),
    ];
    if (listEquals(native, _shown)) return;
    _shown = native;
    _bar.show(native).catchError((Object e) => logFailure("menu", "show: $e"));
  }
}
