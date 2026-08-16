import "package:flutter/material.dart";

/// A menu under the widget [context] belongs to, offered as a route.
///
/// A `MenuAnchor` draws into an overlay, which nothing pops: Android's back key
/// passes straight through it to whatever is behind, and behind the sidebar is
/// the app. A route is what `PopupMenuButton` pushes and why back closes that
/// one, and this is the same thing without having to be the button — the button
/// stays whatever it already was. The [context] has to be the button's own, so
/// callers reach for a `Builder` where their build context is the whole section.
///
/// Each entry carries its action as its value, so it runs once the menu has
/// closed rather than under it. Guard the result with `context.mounted`.
Future<T?> showAnchoredMenu<T>(BuildContext context, List<PopupMenuEntry<T>> items) {
  final button = context.findRenderObject()! as RenderBox;
  final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final under = Offset(0, button.size.height);
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(under, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero) + under, ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}
