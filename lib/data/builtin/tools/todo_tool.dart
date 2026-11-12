import "../../../domain/agent_backend.dart";
import "../../../domain/plan.dart" show planDoneToolName;
import "../../../domain/system_notification.dart";
import "../../../domain/todo.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "turn.dart";

/// The turn's checklist: the whole list in every call, and the list read back
/// as the result. What it is for is the model's own attention as much as the
/// user's view — each call puts what is left in the newest part of the
/// context — so the result repeats it rather than saying "ok".
///
/// It is the plan's light half: no approval, no details, no file. An approved
/// plan is worked through with `plan_done` instead, and the description says
/// so, so the two never track the same work.
class TodoTool extends AgentTool {
  TodoTool(super.offer);

  @override
  String get name => todoToolName;

  @override
  ToolGroup get group => ToolGroup.plan;

  @override
  bool get offered => !offer.oneShot;

  @override
  String get fragment =>
      "`$todoToolName` to keep a task list for work of "
      "several steps";

  @override
  String get description =>
      "Write the task list for the work you are doing, shown to the user as "
      "you go. Use it for work of three or more steps, or whenever the user "
      "gives you several things to do; not for a question, a single edit, or "
      "anything a few tool calls finish. Send the whole list every time: "
      "write it before you start, mark a task in_progress before you begin "
      "it (only one at a time) and completed as soon as it is done, and add "
      "or drop tasks as the work changes. Finish every task or, if you stop "
      "with tasks left, say in your reply which and why. Under an approved "
      "plan, use $planDoneToolName instead.";

  @override
  Map<String, dynamic> get schema => {
    "type": "object",
    "properties": {
      "todos": {
        "type": "array",
        "description": "The whole list, in the order the work goes.",
        "items": {
          "type": "object",
          "properties": {
            "content": {
              "type": "string",
              "description":
                  "The task, as a short imperative: \"Run the widget tests\".",
            },
            "status": {
              "type": "string",
              "enum": [for (final s in TodoStatus.values) s.wire],
            },
          },
          "required": ["content", "status"],
        },
      },
    },
    "required": ["todos"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final list = TodoList.parse(call.argumentsJson);
    if (list == null) {
      yield* toolRejected(
        call,
        'The $todoToolName tool takes {"todos": [{"content": "...", '
        '"status": "pending" | "in_progress" | "completed"}, ...]}, every '
        "task with words in it.",
      );
      return;
    }
    yield toolCalled(call, list.current?.content);
    if (list.problem case final problem?) {
      yield toolFailed(call, problem);
      return;
    }
    turn.todos = list;
    yield toolOk(call, list.summary);
  }

  /// A turn that stops with its own list unfinished is told so, once: a stop
  /// after the reminder is taken as meant. Only the list this turn wrote:
  /// one an earlier turn left is the user's to pick up or not.
  @override
  int get stopNudges => 1;

  @override
  Future<String?> beforeStop(Turn turn) async {
    final left = turn.todos?.unfinished ?? const [];
    if (left.isEmpty) return null;
    return systemNotification([
      "Your task list still has ${left.length} task(s) not completed:",
      for (final item in left) "- ${item.content}",
      "Carry on with them. If one turned out unnecessary, drop it from the "
          "list; if you are stopping with tasks left, say in your reply "
          "which and why.",
    ]);
  }
}
