import "package:flutter/services.dart";
import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../app/app_menus.dart";
import "../app/frontend.dart";
import "../core/platform/form_factor.dart";
import "../providers.dart";
import "app_command.dart";
import "commands.dart";

/// [appMenus] in the platform's menu bar, greyed and titled as the app
/// stands, each pick run by the frontend that mounts this — through its own
/// [navigate] for a [Destination]. Nothing where the platform has no menu
/// bar. Must sit below the Navigator, as the items open their pages from
/// here. The last mounted answers: a restart builds the next before it takes
/// this one down.
class AppMenuSync extends ConsumerStatefulWidget {
  const AppMenuSync({
    super.key,
    this.navigate = flutterNavigate,
    required this.child,
  });

  final Navigate navigate;
  final Widget child;

  @override
  ConsumerState<AppMenuSync> createState() => _AppMenuSyncState();
}

class _AppMenuSyncState extends ConsumerState<AppMenuSync> {
  static _AppMenuSyncState? _answering;
  late final AppMenus _menus = ref.read(appMenusProvider);

  @override
  void initState() {
    super.initState();
    _answering = this;
    _menus.onPicked = _picked;
  }

  @override
  void dispose() {
    if (identical(_answering, this)) {
      _answering = null;
      _menus.onPicked = null;
    }
    super.dispose();
  }

  void _picked(AppItem item) {
    if (mounted) Commands.read(context, ref, widget.navigate).run(item);
  }

  @override
  Widget build(BuildContext context) {
    final menus = _menus;
    if (menus.available && identical(_answering, this)) {
      final commands = Commands.watch(context, ref, widget.navigate);
      menus.show(
        // A Mac's SwiftUI frontend has the platform's own Settings item, the
        // Settings scene's, in this one's place.
        isMac && ref.watch(frontendProvider).swiftUI
            ? _without(Destination.settings)
            : appMenus,
        title: commands.label,
        enabled: (item) => commands.availability(item).isAvailable,
      );
    }
    return widget.child;
  }
}

/// [appMenus] with [item] left out.
List<AppMenu> _without(AppItem item) => [
  for (final menu in appMenus)
    AppMenu(menu.title, menu.role, [
      for (final group in menu.groups) [...group.where((i) => i != item)],
    ]),
];

/// Run the item [event]'s keys make, unless the menu bar holds them. True
/// where it ran, so the key goes no further.
bool runKey(KeyEvent event, WidgetRef ref, Commands Function() commands) {
  if (event is! KeyDownEvent) return false;
  final item = appItemOf(event);
  if (item == null) return false;
  if (ref.read(appMenusProvider).available && inAppMenus(item)) return false;
  return commands().run(item).isAvailable;
}
