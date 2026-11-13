import "models.dart";
import "plan.dart" show PlanTaskStatus;
import "tool_arg.dart";

const todoToolName = "todo";

/// Where one step of a [TodoList] stands. The wire names are Claude Code's
/// `TodoWrite`'s, the shape models are most often trained on.
enum TodoStatus {
  pending("pending"),
  inProgress("in_progress"),
  completed("completed");

  const TodoStatus(this.wire);

  final String wire;

  /// The plan's state it is drawn as.
  PlanTaskStatus get asPlan => switch (this) {
    pending => PlanTaskStatus.pending,
    inProgress => PlanTaskStatus.inProgress,
    completed => PlanTaskStatus.done,
  };

  static TodoStatus? fromWire(Object? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

/// One step: a line saying what it is, and where it stands.
class TodoItem {
  const TodoItem(this.content, this.status);

  final String content;
  final TodoStatus status;

  bool get finished => status == TodoStatus.completed;
}

/// The model's checklist for the turn's work, as its newest `todo` call wrote
/// it. Every call sends the whole list, so the newest call is the list and
/// nothing else is kept: the conversation log is where it lives, a rewind
/// takes it back with the message, and a mirror has it with the reply.
class TodoList {
  const TodoList(this.items);

  final List<TodoItem> items;

  /// The list a call's arguments hold, or null where they are not one: not
  /// an object with a `todos` array of `{content, status}`, a step with no
  /// words, or a status the tool does not know.
  static TodoList? parse(String? argumentsJson) {
    final todos = decodeArgs(argumentsJson)?["todos"];
    if (todos is! List) return null;
    final items = <TodoItem>[];
    for (final todo in todos) {
      if (todo is! Map) return null;
      final content = todo["content"];
      final status = TodoStatus.fromWire(todo["status"]);
      if (content is! String || content.trim().isEmpty || status == null) {
        return null;
      }
      items.add(TodoItem(content.trim(), status));
    }
    return TodoList(items);
  }

  /// The newest list [messages] hold: the last `todo` call that ran, read
  /// back from the newest reply. A call that was refused wrote nothing.
  static TodoList? latestIn(Iterable<Message> messages) {
    for (final message in messages.toList().reversed) {
      if (lastOf(message) case final list?) return list;
    }
    return null;
  }

  /// The list the replies since the last prompt wrote: what the chat shows
  /// while that turn is the latest. A new prompt puts it away until the turn
  /// it starts writes one of its own.
  static TodoList? ofLastTurn(List<Message> messages) {
    for (final message in messages.reversed) {
      if (message.role == MessageRole.user) return null;
      if (lastOf(message) case final list?) return list;
    }
    return null;
  }

  /// The newest list [message] holds, or null where it made no `todo` call
  /// that ran.
  static TodoList? lastOf(Message message) {
    Map<String, ToolResult>? results;
    for (final part in message.parts.reversed) {
      if (part case ToolCallPart(
        :final toolCall,
      ) when toolCall.name == todoToolName) {
        results ??= message.toolResults;
        if ((results[toolCall.id]?.returnCode ?? 0) != 0) continue;
        if (parse(toolCall.argumentsJson) case final list?) return list;
      }
    }
    return null;
  }

  /// Why the model's list cannot stand, or null where it can. One step at a
  /// time is the rule that keeps a step from being passed over unmarked.
  String? get problem {
    final going = _going;
    if (going.length > 1) {
      return "Only one task may be in_progress at a time, and ${going.length} "
          "are. Mark the ones you are not working on now as pending.";
    }
    return null;
  }

  Iterable<TodoItem> get _going =>
      items.where((i) => i.status == TodoStatus.inProgress);

  bool get isEmpty => items.isEmpty;

  bool get allDone => done == items.length;

  int get done => items.where((i) => i.finished).length;

  /// The step under way, where one is.
  TodoItem? get current => _going.firstOrNull;

  List<TodoItem> get unfinished => [
    for (final item in items)
      if (!item.finished) item,
  ];

  /// The list as the model reads it back: what is under way and what is
  /// left, so the next step is in the newest part of its context.
  String get summary {
    if (isEmpty) return "The task list is cleared.";
    if (allDone) return "All ${items.length} tasks are done.";
    final pending = [
      for (final item in items)
        if (item.status == TodoStatus.pending) "- ${item.content}",
    ];
    return [
      "$done of ${items.length} tasks done.",
      if (current case final c?) "In progress: ${c.content}",
      if (pending.isNotEmpty) ...["Left:", ...pending],
    ].join("\n");
  }

  /// The list as it ends a compaction summary that swallowed it.
  String get carried =>
      "Your task list, as you last wrote it with `$todoToolName`:\n$summary";
}

extension ChatTodos on Chat {
  /// The task list the chat shows: the latest turn's.
  TodoList? get todos => TodoList.ofLastTurn(messages);
}
