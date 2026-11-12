import "../../../domain/todo.dart";
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";
import "tool_run.dart";

/// A `todo` call reads as the task it moved to, and opens to the whole list
/// as that call wrote it. Not said aloud: the list is bookkeeping, the reply
/// is what was done.
final class TodoActivity extends ToolActivity {
  const TodoActivity();

  @override
  String get tool => todoToolName;

  @override
  String? get spoken => null;

  static TodoList? _listOf(Run run) =>
      run.failed ? null : TodoList.parse(run.call?.argumentsJson);

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final list = _listOf(run);
    if (list == null) return super.node(reader, run);
    final total = list.items.length;
    final current = list.current;
    return LabelNode(
      this,
      run,
      glyph: TranscriptGlyph.plan,
      text: list.isEmpty
          ? "Cleared the task list"
          : list.unfinished.isEmpty
          ? "All $total tasks done"
          : current != null
          ? "Task ${list.items.indexOf(current) + 1} of $total: "
                "${current.content}"
          : "Task list: ${list.done} of $total done",
      busy: run.going && run.result == null,
    );
  }

  @override
  ActivityDetail? detail(SettingReader reader, Run run) {
    final list = _listOf(run);
    if (list == null) return super.detail(reader, run);
    return ActivityDetail(
      title: "Task list",
      glyph: TranscriptGlyph.plan,
      status: DetailStatus("${list.done} of ${list.items.length} done"),
      sections: [
        DetailSection(
          body: [
            for (final item in list.items)
              "${switch (item.status) {
                TodoStatus.completed => "✓",
                TodoStatus.inProgress => "→",
                TodoStatus.pending => "○",
              }} ${item.content}",
          ].join("\n"),
        ),
      ],
    );
  }
}
