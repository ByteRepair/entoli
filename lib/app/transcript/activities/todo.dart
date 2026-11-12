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
    return LabelNode(
      this,
      run,
      glyph: TranscriptGlyph.plan,
      text: list.label,
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

/// How the frontends word a task list.
extension TodoWords on TodoList {
  /// A `todo` call's label: the task it moved to.
  String get label => switch (current) {
    _ when isEmpty => "Cleared the task list",
    _ when allDone => "All ${items.length} tasks done",
    final current? =>
      "Task ${items.indexOf(current) + 1} of ${items.length}: "
          "${current.content}",
    null => "Task list: $done of ${items.length} done",
  };

  /// The row above the composer: the task under way, or how much is left.
  String get headline => allDone
      ? "All tasks done"
      : current?.content ?? "${items.length - done} left";
}
