import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/file_tools.dart";
import "../../../domain/models.dart";
import "../../fonts.dart";
import "../activity/activity.dart";
import "../activity/label.dart";
import "../activity/tool_run.dart" show toolRunView;
import "tool_ui.dart";

class ReadUI extends ToolUI {
  const ReadUI();

  @override
  String get tool => readToolName;

  @override
  String get spoken => "Read a file";

  @override
  (IconData, String) get approval =>
      (Icons.description_outlined, "Read this file?");
}

/// `write` and `edit` draw what they changed as red/green diff lines rather
/// than a label, where the change is small enough to read at a glance. The
/// before and after come from the call alone — the arguments carry it — so
/// this draws from what conv.jsonl already holds and nothing is captured at
/// execution time. Past [budget] it is the ordinary label.
abstract class _ChangeUI extends ToolUI {
  const _ChangeUI();

  static const budget = 20;
  static const maxArgsLength = 20000;

  /// "Wrote", "Edited": what the label and the drawer say the call did.
  String get verb;

  @override
  (IconData, String) get approval => (Icons.edit_outlined, "Change this file?");

  String _title(Run run) => "$verb ${run.call?.argumentsText ?? ""}".trim();

  @override
  RunView view(WidgetRef ref, Run run) => toolRunView(run, title: _title(run));

  @override
  Widget build(Run run) {
    final lines = _changed(run);
    if (lines == null) return super.build(run);
    final (removed, added) = lines;
    return _DiffLabel(
      title: _title(run),
      removed: removed,
      added: added,
      onTap: (context) => open(context, run),
    );
  }

  (List<String>, List<String>)? _changed(Run run) {
    final call = run.call;
    final result = run.result;
    if (call == null || result == null || result.returnCode != 0) return null;
    if ((call.argumentsJson?.length ?? 0) > maxArgsLength) return null;
    final beforeAfter = _beforeAfter(call);
    if (beforeAfter == null) return null;
    final (removed, added) = _diff(beforeAfter.$1, beforeAfter.$2);
    if (removed.isEmpty && added.isEmpty) return null;
    if (removed.length + added.length > budget) return null;
    return (removed, added);
  }

  /// The before and after the call names, or null where its arguments are
  /// not the shape the tool takes.
  (String, String)? _beforeAfter(ToolCall call);
}

class WriteUI extends _ChangeUI {
  const WriteUI();

  @override
  String get tool => writeToolName;

  @override
  String get spoken => "Wrote a file";

  @override
  String get verb => "Wrote";

  @override
  (String, String)? _beforeAfter(ToolCall call) {
    final args = writeArgsFrom(call.argumentsJson);
    return args == null ? null : ("", args.content);
  }
}

class EditUI extends _ChangeUI {
  const EditUI();

  @override
  String get tool => editToolName;

  @override
  String get spoken => "Edited a file";

  @override
  String get verb => "Edited";

  @override
  (String, String)? _beforeAfter(ToolCall call) {
    final args = editArgsFrom(call.argumentsJson);
    return args == null ? null : (args.oldString, args.newString);
  }
}

class _DiffLabel extends StatelessWidget {
  const _DiffLabel({
    required this.title,
    required this.removed,
    required this.added,
    required this.onTap,
  });

  final String title;
  final List<String> removed;
  final List<String> added;
  final void Function(BuildContext context) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final red = theme.colorScheme.error;
    final green = theme.brightness == Brightness.dark
        ? const Color(0xFF3FB950)
        : const Color(0xFF1A7F37);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () => onTap(context),
        style: labelStyle(theme.colorScheme.onSurfaceVariant, labelText(theme)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.description_outlined, size: labelIcon),
                  const SizedBox(width: labelGap),
                  Text(title),
                ],
              ),
              const SizedBox(height: 4),
              for (final line in removed)
                Text(
                  "- $line",
                  style: TextStyle(
                    fontFamily: monoFamily,
                    fontSize: 12.5,
                    color: red,
                  ),
                ),
              for (final line in added)
                Text(
                  "+ $line",
                  style: TextStyle(
                    fontFamily: monoFamily,
                    fontSize: 12.5,
                    color: green,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lines the two texts do not share, found by trimming what they do: the
/// common head, then the common tail. Whatever is left of [before] is
/// removed; of [after], added. Interior structure is not looked for, so a
/// reordering reads as remove-and-add — and the budget answers for the worst
/// of it, which is why the same lines can come back in either order.
///
/// The empty text splits to one empty line, which is no line anyone wrote —
/// dropped when it is all the trimming left, kept where it is a real blank
/// line beside others.
(List<String>, List<String>) _diff(String before, String after) {
  final oldLines = before.split("\n");
  final newLines = after.split("\n");
  var start = 0;
  while (start < oldLines.length &&
      start < newLines.length &&
      oldLines[start] == newLines[start]) {
    start++;
  }
  var endOld = oldLines.length;
  var endNew = newLines.length;
  while (endOld > start &&
      endNew > start &&
      oldLines[endOld - 1] == newLines[endNew - 1]) {
    endOld--;
    endNew--;
  }
  final removed = oldLines.sublist(start, endOld);
  final added = newLines.sublist(start, endNew);
  if (removed.singleEmpty) removed.clear();
  if (added.singleEmpty) added.clear();
  return (removed, added);
}

extension on List<String> {
  /// Just the one empty line — the whole of a split empty string, or a middle
  /// the trim left with nothing else in it.
  bool get singleEmpty => length == 1 && this[0].isEmpty;
}
