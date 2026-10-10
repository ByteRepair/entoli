import "package:flutter/material.dart";

/// Drops the caret when the soft keyboard goes away, from the root of the app —
/// the fact is the keyboard's rather than any one field's. Why the view insets
/// are the only report of it, and why it is remembered rather than looked up, is
/// in "The keyboard and the caret" in `AGENTS.md`.
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
    // Reading the insets is what subscribes to them, and only a change in them
    // rebuilds this. Above every `Scaffold`, which takes the bottom one out.
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _typing = FocusManager.instance.primaryFocus;
    } else {
      final node = _typing;
      _typing = null;
      // Focus that moved on since took the keyboard down with it, and a pushed
      // route's scope or a reply's selection is not this widget's to take away.
      // Unfocusing from a build is safe: it lands in a microtask.
      if (node != null && node.hasFocus) node.unfocus();
    }
    return widget.child;
  }
}
