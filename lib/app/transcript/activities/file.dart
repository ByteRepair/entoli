import "../../../domain/file_tools.dart";
import "../../../domain/models.dart";
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";
import "tool_run.dart";

final class ReadActivity extends ToolActivity {
  const ReadActivity();

  @override
  String get tool => readToolName;

  @override
  String get spoken => "Read a file";

  @override
  (TranscriptGlyph, String) get approval =>
      (TranscriptGlyph.file, "Read this file?");
}

/// `write` and `edit` show what they changed as red/green lines rather than
/// a label, where the change is small enough to read at a glance. The before
/// and after come from the call alone — the arguments carry it — so this is
/// read from what conv.jsonl already holds. Past [budget] it is the ordinary
/// label.
abstract class ChangeActivity extends ToolActivity {
  const ChangeActivity();

  static const budget = 20;
  static const maxArgsLength = 20000;

  /// "Wrote", "Edited": what the label and the detail say the call did.
  String get verb;

  @override
  (TranscriptGlyph, String) get approval =>
      (TranscriptGlyph.edit, "Change this file?");

  @override
  String title(Run run) => "$verb ${run.call?.argumentsText ?? ""}".trim();

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final lines = _changed(run);
    if (lines == null) return super.node(reader, run);
    final (removed, added) = lines;
    return DiffNode(
      this,
      run,
      title: title(run),
      removed: removed,
      added: added,
    );
  }

  (List<String>, List<String>)? _changed(Run run) {
    final call = run.call;
    final result = run.result;
    if (call == null || result == null || result.returnCode != 0) return null;
    if ((call.argumentsJson?.length ?? 0) > maxArgsLength) return null;
    final beforeAfter = beforeAfterOf(call);
    if (beforeAfter == null) return null;
    final (removed, added) = lineDiff(beforeAfter.$1, beforeAfter.$2);
    if (removed.isEmpty && added.isEmpty) return null;
    if (removed.length + added.length > budget) return null;
    return (removed, added);
  }

  /// The before and after the call names, or null where its arguments are
  /// not the shape the tool takes.
  (String, String)? beforeAfterOf(ToolCall call);
}

final class WriteActivity extends ChangeActivity {
  const WriteActivity();

  @override
  String get tool => writeToolName;

  @override
  String get spoken => "Wrote a file";

  @override
  String get verb => "Wrote";

  @override
  (String, String)? beforeAfterOf(ToolCall call) {
    final args = writeArgsFrom(call.argumentsJson);
    return args == null ? null : ("", args.content);
  }
}

final class EditActivity extends ChangeActivity {
  const EditActivity();

  @override
  String get tool => editToolName;

  @override
  String get spoken => "Edited a file";

  @override
  String get verb => "Edited";

  @override
  (String, String)? beforeAfterOf(ToolCall call) {
    final args = editArgsFrom(call.argumentsJson);
    return args == null ? null : (args.oldString, args.newString);
  }
}

/// Lines the two texts do not share, found by trimming what they do: the
/// common head, then the common tail. Interior structure is not looked for,
/// so a reordering reads as remove-and-add — and the budget answers for the
/// worst of it.
///
/// The empty text splits to one empty line, which is no line anyone wrote —
/// dropped when it is all the trimming left, kept where it is a real blank
/// line beside others.
(List<String>, List<String>) lineDiff(String before, String after) {
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
  bool get singleEmpty => length == 1 && this[0].isEmpty;
}
