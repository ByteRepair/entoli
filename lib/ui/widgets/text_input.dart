import "package:flutter/material.dart";
import "package:flutter/services.dart";

/// Writes [text] over [start]..[end] of [controller], leaving the caret after
/// it.
void replaceIn(TextEditingController controller, int start, int end, String text) {
  controller.value = TextEditingValue(
    text: controller.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}

/// Makes Tab type an indent into [controller] rather than move the focus on.
///
/// It wraps a field rather than being one, so a field with bindings of its own
/// nests them inside this and takes Tab first. See the AGENTS.md beside this.
class TabIndents extends StatelessWidget {
  const TabIndents({super.key, required this.controller, required this.child});

  /// Spaces rather than a tab character: what is typed into these fields is a
  /// prompt, and a tab in one reaches the model as whitespace nothing renders.
  static const _spaces = "  ";

  final TextEditingController controller;
  final Widget child;

  void _indent() {
    final selection = controller.selection;
    // A field focused by traversal rather than by a tap has no selection at
    // all, and the -1 that leaves is not a range anything can be written over.
    final at = selection.isValid
        ? selection
        : TextSelection.collapsed(offset: controller.text.length);
    replaceIn(controller, at.start, at.end, _spaces);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.tab): _indent},
        child: child,
      );
}
