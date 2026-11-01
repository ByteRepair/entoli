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
Future<T?> showAnchoredMenu<T>(
  BuildContext context,
  List<PopupMenuEntry<T>> items,
) {
  final (button, overlay) = _anchorOf(context);
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      button.shift(Offset(0, button.height)),
      Offset.zero & overlay,
    ),
    items: items,
  );
}

/// Where the widget [context] belongs to is, in the navigator's overlay, and
/// how big that overlay is: what both anchored popups place themselves by.
(Rect, Size) _anchorOf(BuildContext context) {
  final button = context.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  return (
    button.localToGlobal(Offset.zero, ancestor: overlay) & button.size,
    overlay.size,
  );
}

/// What [builder] draws, just above the widget [context] belongs to and
/// centred on it — below where there is no room above — and kept on screen:
/// a popup that is not a list of entries, offered as a route for the reasons
/// [showAnchoredMenu] is one, so back, Escape and a tap outside close it. The
/// popup pops itself with its answer.
Future<T?> showAnchoredPopup<T>(BuildContext context, WidgetBuilder builder) {
  final (button, _) = _anchorOf(context);
  return Navigator.of(context).push(
    _AnchoredPopupRoute<T>(
      anchor: button,
      builder: builder,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

class _AnchoredPopupRoute<T> extends PopupRoute<T> {
  _AnchoredPopupRoute({
    required this.anchor,
    required this.builder,
    required this.barrierLabel,
  });

  final Rect anchor;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  /// Decided before the popup is measured, so its layout and the edge it
  /// grows from agree: above unless the button is too near the top for a
  /// popup of a button's height or so to fit.
  late final bool _above = anchor.top >= _AboveOrBelow.room;

  /// The transition is inside the layout rather than around it, so the popup
  /// grows from the edge facing the button, not from the middle of the screen.
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final eased = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return CustomSingleChildLayout(
      delegate: _AboveOrBelow(anchor, above: _above),
      child: FadeTransition(
        opacity: eased,
        child: ScaleTransition(
          alignment: _above ? Alignment.bottomCenter : Alignment.topCenter,
          scale: Tween(begin: 0.9, end: 1.0).animate(eased),
          child: builder(context),
        ),
      ),
    );
  }
}

/// The popup centred on the button across, and just above it or just below,
/// moved only as far as staying on screen needs.
class _AboveOrBelow extends SingleChildLayoutDelegate {
  const _AboveOrBelow(this.anchor, {required this.above});

  final Rect anchor;
  final bool above;

  static const _margin = 8.0;
  static const _gap = 4.0;

  /// What [above] needs over the button: a popup of about a row's height,
  /// its gap and the screen's margin.
  static const room = 64.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        constraints.biggest,
      ).deflate(const EdgeInsets.all(_margin));

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    _within(
      anchor.center.dx - childSize.width / 2,
      size.width - childSize.width,
    ),
    _within(
      above ? anchor.top - _gap - childSize.height : anchor.bottom + _gap,
      size.height - childSize.height,
    ),
  );

  static double _within(double at, double room) =>
      at.clamp(_margin, (room - _margin).clamp(_margin, double.infinity));

  @override
  bool shouldRelayout(_AboveOrBelow old) =>
      old.anchor != anchor || old.above != above;
}
