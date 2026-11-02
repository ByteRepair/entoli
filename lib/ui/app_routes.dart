import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

/// What the app's Navigator holds over the conversation, which is its first
/// route. On the Navigator from `main`, whichever shell draws the app: the
/// Flutter one asks it how to get back to the conversation, and the native
/// one also whether a page covers it.
class AppRoutes extends NavigatorObserver {
  final List<Route<Object?>> _stack = [];

  /// How many routes the Navigator holds, the conversation's included.
  int get depth => _stack.length;

  /// A page over the conversation. A dialog is a route too and covers
  /// nothing: it draws over the page under it.
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

final appRoutesProvider = Provider<AppRoutes>((ref) => AppRoutes());

/// Close the pages over the conversation, one at a time and each the way the
/// back key would, so a page that asks before it goes — an edited file, a
/// prompt being written — is asked. Answers whether the conversation was
/// reached: a page that asks is left asking, its question on screen, and
/// what wanted the conversation does nothing, rather than happen under a
/// page the user is still deciding about. What opening a chat, a new one or
/// another project does first, from the sidebar or the palette: what the
/// pane shows is what a page pushed over it replaces.
///
/// A back that does not take a route off — a page saying no, or opening its
/// question, which is a route more — stops it: asking again would close the
/// question and ask again, for ever.
Future<bool> toConversation(BuildContext context, AppRoutes routes) async {
  final navigator = Navigator.of(context);
  while (routes.depth > 1) {
    final before = routes.depth;
    await navigator.maybePop();
    if (routes.depth >= before) return false;
  }
  return true;
}
