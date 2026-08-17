import "package:flutter/material.dart";

/// Drops the caret when the soft keyboard goes away.
///
/// Android closes the keyboard on a back gesture without telling Flutter, and
/// on touch the framework never unfocuses a field for a tap outside it — so the
/// field goes on holding focus and blinking over a conversation nobody is
/// typing in. The view insets are the only report of the keyboard closing.
///
/// It wraps the app rather than a field: the fact is the keyboard's, not any one
/// page's, and state held anywhere lower is lost the next time that page is
/// remounted.
class FocusFollowsKeyboard extends StatefulWidget {
  const FocusFollowsKeyboard({super.key, required this.child});

  final Widget child;

  @override
  State<FocusFollowsKeyboard> createState() => _FocusFollowsKeyboardState();
}

class _FocusFollowsKeyboardState extends State<FocusFollowsKeyboard> {
  FocusNode? _typing;

  @override
  Widget build(BuildContext context) {
    // Reading the insets here is what subscribes to them, and `MediaQuery` is
    // an `InheritedModel`, so only a change in them rebuilds this. Above every
    // `Scaffold`, which takes the bottom inset out of what it lays out.
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _typing = FocusManager.instance.primaryFocus;
    } else {
      final node = _typing;
      _typing = null;
      // Whatever the keyboard was up for, and only while it still holds the
      // caret: focus that has moved on since took the keyboard down with it,
      // and a pushed route's scope or a reply's selection is not this widget's
      // to take away. `unfocus` here is applied in a microtask, after the frame.
      if (node != null && node.hasFocus) node.unfocus();
    }
    return widget.child;
  }
}
