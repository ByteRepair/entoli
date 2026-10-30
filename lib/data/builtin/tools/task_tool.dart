import "dart:async";

import "../../../domain/agent_backend.dart";
import "../../../domain/tool_arg.dart";
import "../llm/llm_client.dart";
import "../templates.dart"
    show notStarted, substitute, systemProse, turnStopped;
import "agent_tool.dart";
import "turn.dart";
import "../tool_outcome.dart";

/// Spawns a sub-agent that runs a task to completion and returns its final
/// text. The sub-agent runs in its own session under the named `@agent`'s
/// prompt, with the same model and workspace as the parent.
///
/// It runs as a batch: every `task` call in a message runs concurrently,
/// capped by [BuiltinOptions.maxConcurrentSubAgents], once the message's
/// other calls are done.
class TaskTool extends AgentTool {
  TaskTool(super.offer);

  @override
  ToolGroup? get group => null;

  @override
  String get name => taskToolName;

  @override
  bool get offered => offer.caps.task;

  @override
  String get runningLabel => "Working on a sub-task";

  @override
  String get fragment => "`$taskToolName` to delegate a task to a sub-agent";

  @override
  String get section =>
      substitute(systemProse("task"), {"task_tool": taskToolName});

  @override
  String get description =>
      "Run a sub-agent on a delegated task. The "
      "sub-agent has its own conversation, runs under the named agent's "
      "prompt, and returns its final output when it finishes. Use it to fan "
      "out work: each call runs independently, so several `task` calls in one "
      "message run concurrently. The sub-agent can call `bash` and "
      "`websearch`/`webfetch` itself, so prefer it for anything that would "
      "crowd the main conversation — a search, an extraction, a verification.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "agent": {
        "type": "string",
        "description": "The @agent name to run under (e.g. \"general\").",
      },
      "prompt": {
        "type": "string",
        "description":
            "The task for the sub-agent. Write it as a complete "
            "instruction — the sub-agent sees nothing else of this "
            "conversation.",
      },
    },
    "required": ["agent", "prompt"],
  };

  @override
  bool get batched => true;

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) => runAll([call], turn);

  /// Run a batch of `task` calls concurrently, capped to
  /// [BuiltinOptions.maxConcurrentSubAgents]. Results stream as each
  /// sub-agent resolves; the projection pairs each back to its call by id, so
  /// finishing out of order costs nothing.
  @override
  Stream<AgentEvent> runAll(List<LlmToolCall> calls, Turn turn) async* {
    if (turn.cancelled) {
      // Answered all the same, so the next turn is not rejected for missing
      // results.
      for (final call in calls) {
        yield* toolRejected(call, notStarted);
      }
      return;
    }
    final parsed = [for (final call in calls) _argsOf(call)];

    // The calls up front, in the order the model made them. They are one
    // message's worth of calls and the projection reads them back in the order
    // their parts are in — emitted as each sub-agent resolved, they went into
    // the log in finishing order, which is not an order the model ever chose.
    for (var i = 0; i < calls.length; i++) {
      final args = parsed[i];
      yield toolCalled(
        calls[i],
        args == null ? null : "@${args.agent}: ${_truncate(args.prompt, 200)}",
      );
    }

    final controller = StreamController<AgentEvent>();

    Future<void> runOne(int index) async {
      final call = calls[index];
      final args = parsed[index];
      if (turn.cancelled) {
        controller.add(toolFailed(call, turnStopped));
        return;
      }
      if (args == null) {
        controller.add(
          toolFailed(
            call,
            'The $taskToolName tool takes {"agent": "...", "prompt": "..."}.',
          ),
        );
        return;
      }
      final (:agent, :prompt) = args;
      controller.add(
        SubAgentStartEvent(
          id: call.id,
          agent: agent,
          prompt: _truncate(prompt, 80),
        ),
      );
      final result = await turn.subAgents!.run(agent, prompt, callId: call.id);
      controller.add(
        SubAgentEndEvent(id: call.id, failed: result.returnCode != 0),
      );
      controller.add(ToolResultEvent(toolRan(call, result)));
    }

    // A bounded fan-out: maxConcurrentSubAgents workers, each taking the next
    // call as it finishes one.
    var next = 0;
    Future<void> worker() async {
      while (next < calls.length) {
        await runOne(next++);
      }
    }

    final allDone = Future.wait([
      for (
        var w = 0;
        w < turn.options.maxConcurrentSubAgents && w < calls.length;
        w++
      )
        worker(),
    ]).whenComplete(controller.close);
    yield* controller.stream;
    await allDone;
  }

  /// `agent` and `prompt` out of a call's arguments, or null when the JSON is
  /// not what the tool takes.
  static ({String agent, String prompt})? _argsOf(LlmToolCall call) {
    final agent = stringArg(call.argumentsJson, "agent");
    final prompt = stringArg(call.argumentsJson, "prompt");
    if (agent == null || prompt == null) return null;
    return (agent: agent, prompt: prompt);
  }

  static String _truncate(String text, int max) {
    final t = text.trim().replaceAll("\n", " ");
    return t.length <= max ? t : "${t.substring(0, max - 1)}…";
  }
}
