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

  /// What the caller's `NotificationListener<ScrollNotification>` forwards.
  bool onNotification(ScrollNotification notification) {
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
      controller.hasClients &&
      controller.position.nearBottom(0.0);
}