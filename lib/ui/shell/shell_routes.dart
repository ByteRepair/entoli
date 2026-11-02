import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

/// Whether a page is pushed over the conversation. On the app's Navigator,
/// from `main`; only the shell reads it.
class ShellRoutes extends NavigatorObserver {
  final List<Route<Object?>> _stack = [];

  /// How many routes the Navigator holds, the conversation's included.
  int get depth => _stack.length;

  /// A page over the first route, which is the conversation's. A dialog is a
  /// route too and covers nothing: it draws over the Flutter view alone.
  final ValueNotifier<bool> covered = ValueNotifier(false);

  void _changed() =>
      covered.value = _stack.skip(1).any((route) => route is PageRoute);

  @override
  void didPush(Route<Object?> route, Route<Object?>? previousRoute) {
    _stack.add(route);
    _changed();
  }

  @override
  void didPop(Route<Object?> route, Route<Object?>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<Object?> route, Route<Object?>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<Object?>? newRoute, Route<Object?>? oldRoute}) {
    final at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (newRoute != null) {
      at < 0 ? _stack.add(newRoute) : _stack[at] = newRoute;
    } else if (at >= 0) {
      _stack.removeAt(at);
    }
    _changed();
  }
}

final shellRoutesProvider = Provider<ShellRoutes>((ref) => ShellRoutes());

/// Close the pages over the conversation, one at a time and each the way the
/// back key would, so a page that asks before it goes — a prompt being
/// written — is asked, and stops here if it says no. What a pick in the
/// sidebar or the palette does first: in a split view the sidebar says what
/// the detail shows, and a page pushed in the detail is what it replaces.
Future<void> toConversation(BuildContext context, ShellRoutes routes) async {
  final navigator = Navigator.of(context);
  while (routes.depth > 1) {
    final before = routes.depth;
    await navigator.maybePop();
    if (routes.depth == before) return;
  }
}
