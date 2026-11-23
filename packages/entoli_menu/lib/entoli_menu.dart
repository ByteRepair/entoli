/// The menu bar on macOS and iPadOS, the core's [MenuBarHost] over the
/// Pigeon protocol in `pigeons/menu.dart`. See `lib/AGENTS.md`.
library;

import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/menu_bar.dart";
import "package:flutter/foundation.dart" show listEquals;

import "src/menu_contract.g.dart";

/// The platform's menu bar. Make one per process: it answers the platform's
/// channel.
MenuBarHost nativeMenuBar() => _NativeMenuBar();

/// Sent whole and only when what it says changed.
class _NativeMenuBar implements MenuBarHost, NativeMenuPicks {
  _NativeMenuBar() {
    NativeMenuPicks.setUp(this);
  }

  final NativeMenuBar _bar = NativeMenuBar();
  List<NativeMenu>? _shown;
  void Function(String id)? _picked;

  @override
  set onPicked(void Function(String id)? picked) => _picked = picked;

  @override
  void picked(String id) => _picked?.call(id);

  @override
  void show(List<MenuBarMenu> menus) {
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
                    title: item.title,
                    key: item.key,
                    shift: item.shift,
                    alt: item.alt,
                    enabled: item.enabled,
                    symbol: item.symbol,
                  ),
              ],
          ],
          role: switch (menu.role) {
            MenuBarRole.app => NativeMenuRole.app,
            MenuBarRole.file => NativeMenuRole.file,
            MenuBarRole.view => NativeMenuRole.view,
            MenuBarRole.help => NativeMenuRole.help,
            MenuBarRole.own => NativeMenuRole.own,
          },
        ),
    ];
    if (listEquals(native, _shown)) return;
    _shown = native;
    _bar.show(native).catchError((Object e) => logFailure("menu", "show: $e"));
  }
}
