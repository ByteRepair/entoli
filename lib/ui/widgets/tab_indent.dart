import "package:flutter/material.dart";
import "package:flutter/services.dart";

/// What Tab types. Two spaces rather than a tab character: what is typed into
/// these fields is a prompt, and a literal tab in one survives to the model as
/// whitespace nothing renders.
const String tabIndent = "  ";

class _IndentIntent extends Intent {
  const _IndentIntent();
}

/// Types [tabIndent] over the selection, leaving the caret after it.
void insertTabIndent(TextEditingController controller) {
  final value = controller.value;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: value.text.length);
  controller.value = TextEditingValue(
    text: value.text.replaceRange(selection.start, selection.end, tabIndent),
    selection: TextSelection.collapsed(offset: selection.start + tabIndent.length),
  );
}

/// Makes Tab indent [controller] rather than move the focus on.
///
/// It wraps the field instead of being one, so a field with its own Tab
/// binding nests that binding *inside* this: shortcuts resolve from the focus
/// outwards, so the composer's completion menu keeps Tab while it has a match
/// and falls through to here the rest of the time. Shift+Tab is left alone, so
/// there is always a key that leaves the field.
class TabIndents extends StatelessWidget {
  const TabIndents({super.key, required this.controller, required this.child});

  final TextEditingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const {SingleActivator(LogicalKeyboardKey.tab): _IndentIntent()},
        child: Actions(
          actions: {
            _IndentIntent: CallbackAction<_IndentIntent>(
              onInvoke: (_) => insertTabIndent(controller),
            ),
          },
          child: child,
        ),
      );
}
