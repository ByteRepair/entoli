import "package:flutter/gestures.dart" show PointerDeviceKind;
import "package:flutter/rendering.dart" show ScrollDirection;
import "package:flutter/widgets.dart";

extension NearBottom on ScrollPosition {
  /// Whether the view is close enough to the end to count as reading the
  /// latest — which is what decides whether there is a way back down to
  /// offer. How close is the caller's: a conversation gives itself a
  /// screenful, a five-line transcript none.
  bool nearBottom(double slack) => maxScrollExtent - pixels <= slack;
}

/// Whether a list keeps itself at the end while new content lands on it.
///
/// The answer is the user's, not the position's: a scroll gesture toward the
/// older messages detaches — however small, and however near the end it
/// stops, which is the drag a per-tick position test could never get away
/// from — and reaching the end again by any means attaches. A jump button's
/// animation lands there, so it re-pins without being told; a drag down that
/// stops short does not, and the way down it leaves is the button.
///
/// A gesture is the only thing that detaches, which is why the open-time
/// settles cannot.
class ScrollFollow {
  ScrollFollow(this.controller);

  final ScrollController controller;

  bool _following = true;

  /// Jumps to the end once this frame's layout has set the extent to land
  /// on. The caller fires it each time new content arrives, which while a
  /// reply streams is every frame — hence the jump rather than an animation,
  /// and the guard rather than a position test: a scroll the user has in
  /// progress must not be jumped over.
  void jumpIfFollowing() {
    if (!_following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_following ||
          !controller.hasClients ||
          controller.position.isScrollingNotifier.value) {
        return;
      }
      controller.jumpTo(controller.position.maxScrollExtent);
    });
  }

  /// Stop following, for a move away from the end the caller makes itself —
  /// which no gesture announces. Arriving at the end attaches again, as ever.
  void detach() => _following = false;

  /// Follow again and go to the end, for the user saying something: what they
  /// sent is the latest, wherever they had scrolled to.
  void attach() {
    _following = true;
    jumpIfFollowing();
  }

  double? _viewport;

  /// What the caller's `NotificationListener` forwards: its scroll
  /// notifications, and its metrics, of which only the viewport's size
  /// matters here — the keyboard coming up would otherwise leave the end it
  /// was following under the keys. The content growing is the caller's to
  /// say, by [jumpIfFollowing].
  bool onNotification(Notification notification) {
    if (notification is ScrollMetricsNotification) {
      final viewport = notification.metrics.viewportDimension;
      if (_viewport != null && viewport != _viewport) jumpIfFollowing();
      _viewport = viewport;
      return false;
    }
    if (notification is UserScrollNotification) {
      // On a normal (non-reversed) list `forward` is the user's drag running
      // toward the older messages — the gesture that says stop — and
      // `reverse` the way back down. The reverse arm does not itself attach:
      // a fling lands where it lands, and what attaches is arriving.
      if (notification.direction == ScrollDirection.forward) {
        _following = false;
      }
    } else if (notification is ScrollUpdateNotification && _atEnd) {
      _following = true;
    }
    return false;
  }

  bool get _atEnd =>
      controller.hasClients && controller.position.nearBottom(0.0);
}

/// Drops focus on a touch drag toward the older messages, which takes a soft
/// keyboard down with it, as a phone's own conversations do. A drag back
/// down leaves it, and so do a wheel and a trackpad, so a desktop's composer
/// keeps its caret. The drag's kind rather than the keyboard's insets, which
/// a `Scaffold` above takes out of what it hands its body.
class KeyboardDismissOnScrollBack extends StatefulWidget {
  const KeyboardDismissOnScrollBack({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardDismissOnScrollBack> createState() =>
      _KeyboardDismissOnScrollBackState();
}

class _KeyboardDismissOnScrollBackState
    extends State<KeyboardDismissOnScrollBack> {
  var _touch = false;

  bool _scrolled(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _touch = notification.dragDetails?.kind == PointerDeviceKind.touch;
    } else if (notification is ScrollUpdateNotification &&
        _touch &&
        notification.dragDetails != null &&
        (notification.scrollDelta ?? 0) < 0) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _scrolled,
        child: widget.child,
      );
}
