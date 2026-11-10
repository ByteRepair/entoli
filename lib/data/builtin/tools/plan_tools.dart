import "dart:io";

import "package:path/path.dart" as p;

import "../../../domain/agent_backend.dart";
import "../../../domain/ask.dart";
import "../../../domain/plan.dart";
import "../../../domain/shell.dart";
import "../../../domain/system_notification.dart";
import "../../../domain/tool_arg.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "file_tools.dart" show gatedFileRun;
import "turn.dart";

/// The plan tools, over a `PLAN.md` in the chat's own workspace. Named in
/// `lib/domain/plan.dart` beside the parser, the way `artifactToolName` is.
///
/// The file is the model's own writing: the tools are line edits over it,
/// written through `fs` directly rather than `edit` — the tools own the
/// plan's lines, and an `edit` against them would be two writers on one file.
/// The trio rides the floor beside the file tools, so a device with no shell
/// has them; a sub-agent does not.
abstract class _PlanTool extends AgentTool {
  _PlanTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.plan;

  @override
  bool get offered => !offer.oneShot;
}

/// Where [turn]'s plan is, and what it holds — null where there is none. The
/// one reader the plan tools and the agent share.
String planPath(Turn turn) => p.join(turn.workspace, planFileName);

Future<String?> readPlan(Turn turn) async {
  final file = File(planPath(turn));
  if (!file.existsSync()) return null;
  return file.readAsString();
}

/// What a plan tool says when there is nothing to work from, or null where
/// the file is there with tasks in it.
String? _planMissing(String? plan) {
  if (plan == null) {
    return "There is no $planFileName in the workspace yet. Record the "
        "first task with $planAddToolName.";
  }
  return planTasksFrom(plan).isEmpty
      ? "$planFileName holds no tasks. Add them with $planAddToolName."
      : null;
}

/// Record a task. One call per task, in the order the work goes, so the plan
/// reads as an order rather than a heap; the call is reported with the task
/// as its text, so the chat's label reads the plan growing.
class PlanAddTool extends _PlanTool {
  PlanAddTool(super.offer);

  @override
  String get name => planAddToolName;

  @override
  String get fragment =>
      "`$planAddToolName`/`$planNextToolName`/"
      "`$planDoneToolName` to work through a plan ($planFileName in the "
      "workspace)";

  @override
  String get description =>
      "Add one task to the plan ($planFileName in the "
      "workspace). One call per task, in the order the work goes. The user "
      "reads every task and its details before approving, and "
      "$planNextToolName hands the details back when the task is taken, so "
      "write them to be worked from: the approach, the files or parts "
      "touched, decisions and risks, and how the result will be checked.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "task": {
        "type": "string",
        "description": "The task's title, one line — what will be done.",
      },
      "details": {
        "type": "string",
        "description":
            "The plan for this task, in markdown: how it will "
            "be done, what it touches, and how it will be verified.",
      },
      "section": {
        "type": "string",
        "description":
            "Optional heading to file it under. Tasks without "
            "one go under \"$planDefaultSection\".",
      },
    },
    "required": ["task", "details"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final task = stringArg(call.argumentsJson, "task");
    if (task == null) {
      yield* toolRejected(
        call,
        'The $planAddToolName tool takes {"task": "..."}; that argument '
        "was missing.",
      );
      return;
    }
    final details = stringArg(call.argumentsJson, "details");
    if (details == null) {
      yield* toolRejected(
        call,
        'The $planAddToolName tool takes {"task": "...", "details": "..."}; '
        "the details were missing. Write the plan for this task: how it "
        "will be done, what it touches, and how it will be verified.",
      );
      return;
    }
    final section = stringArg(call.argumentsJson, "section");
    yield toolCalled(call, task);
    final path = planPath(turn);
    yield* gatedFileRun(turn, call, path, planAddToolName, () async {
      final updated = planAddTask(
        await readPlan(turn),
        task,
        section: section,
        details: details,
      );
      await File(path).writeAsString(updated);
      return ShellResult(
        returnCode: 0,
        output: planAddResult(task, planProgress(updated)),
      );
    });
  }
}

/// Take the next task. The mark in the file is the fact; the result is what
/// the model says it is working on. Nothing to take is the answer, not a
/// failure: the plan being finished is exactly the moment the model calls
/// present_plan.
class PlanNextTool extends _PlanTool {
  PlanNextTool(super.offer);

  @override
  String get name => planNextToolName;

  @override
  String get description =>
      "Take the next pending task of the plan and mark "
      "it as being worked on, answering its number and its plan. Only needed "
      "to pick a plan back up: Go and $planDoneToolName already take the "
      "next task. \"All tasks done.\" when nothing is left.";

  @override
  Map<String, dynamic> get schema => const {"type": "object", "properties": {}};

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    yield toolCalled(call);
    final plan = await readPlan(turn);
    final missing = _planMissing(plan);
    final next = planNext(plan);
    if (next == null) {
      yield toolOk(call, missing ?? "All tasks done.");
      return;
    }
    yield toolOk(call, await _take(turn, plan!, next));
  }
}

/// Mark [task] of [plan] in progress, write the plan, and answer with the
/// task's own plan. Every way a task is taken — `plan_next`, Go, and
/// `plan_done` going on to the next — comes through here. The index came
/// from the text just read, so the mark cannot miss.
Future<String> _take(Turn turn, String plan, PlanTask task) async {
  final marked = planMark(plan, task.index, PlanTaskStatus.inProgress)!;
  await File(planPath(turn)).writeAsString(marked);
  return planNextResult(task, planProgress(marked));
}

/// The next task, where [plan] has none under way to finish first.
PlanTask? _nextToTake(String plan) =>
    planUnderWay(plan) ? null : planNext(plan);

/// Finish a task: by number or by enough of its text to identify it.
/// Ambiguous is refused with the candidates, not guessed.
class PlanDoneTool extends _PlanTool {
  PlanDoneTool(super.offer);

  @override
  String get name => planDoneToolName;

  @override
  String get description =>
      "Mark a task of the plan done: by number, or by naming enough of the "
      "task's text to identify it. Takes the next task in the same call and "
      "answers its plan, so go straight on to it.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "task": {
        "type": "string",
        "description": "The task's number, or the start of its text.",
      },
    },
    "required": ["task"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final task = stringArg(call.argumentsJson, "task");
    if (task == null) {
      yield* toolRejected(
        call,
        'The $planDoneToolName tool takes {"task": "..."} — the task\'s '
        "number, or the start of its text; that argument was missing.",
      );
      return;
    }
    yield toolCalled(call, task);
    final plan = await readPlan(turn);
    final missing = _planMissing(plan);
    if (missing != null) {
      yield toolFailed(call, missing);
      return;
    }
    final found = planFind(plan, task);
    if (found == null) {
      final candidates = planCandidates(
        plan,
        task,
      ).map((t) => "${t.index}. ${t.text}").toList();
      yield toolFailed(
        call,
        candidates.isEmpty
            ? "No task matches \"$task\". Read $planFileName for the "
                  "tasks and their numbers."
            : "\"$task\" matches more than one task: ${candidates.join("; ")}. "
                  "Name it by number, or by more of its text.",
      );
      return;
    }
    // The index came from the text just read, so the mark cannot miss.
    final marked = planMark(plan, found.index, PlanTaskStatus.done)!;
    final done = planDoneResult(found, planProgress(marked));
    // The next task is taken in the same call and its plan handed back, so
    // working through a plan costs one call per task rather than two.
    final next = _nextToTake(marked);
    if (next != null) {
      yield toolOk(
        call,
        "$done\n\nNow taken — ${await _take(turn, marked, next)}",
      );
      return;
    }
    await File(planPath(turn)).writeAsString(marked);
    final (finished, total) = planProgress(marked);
    yield toolOk(call, finished == total ? "$done\n\nAll tasks done." : done);
  }

  /// A plan under way with tasks left: said where the model replies with no
  /// tool call, so a progress report does not end the work. Asked of this
  /// one plan tool, so it is said once and only where the plan is offered.
  @override
  Future<String?> beforeStop(Turn turn) async {
    final plan = await readPlan(turn);
    if (!planUnderWay(plan)) return null;
    final open = [
      for (final t in planTasksFrom(plan))
        if (t.status != PlanTaskStatus.done) "${t.index}. ${t.text}",
    ];
    return systemNotification([
      "The approved plan still has ${open.length} task(s) not done:",
      ...open,
      "Carry on with the work. If you are blocked or need a decision, ask "
          "the user with $askToolName; if a task turned out unnecessary, "
          "mark it done and say why.",
    ]);
  }
}

/// The plan, put to the user: the chat draws the call as the plan itself,
/// read off $planFileName, and the Go / changes question the panel asks sits
/// under it — one call, so the model cannot show the plan without asking
/// about it, or ask without showing it. It parks the turn on the panel's
/// answer, so it rides `ask`: a turn with nobody to answer is not offered it.
class PresentPlanTool extends AgentTool {
  PresentPlanTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.plan;

  @override
  String get name => presentPlanToolName;

  @override
  bool get offered => offer.caps.ask;

  @override
  String get runningLabel => "Presenting the plan";

  @override
  String get fragment =>
      "`$presentPlanToolName` to put the plan to the user for approval";

  @override
  String get description =>
      "Present the plan for approval when the last "
      "task is recorded. The chat shows every task with its details, then "
      "asks the user: Go, or type the changes they want. Do not start "
      "executing until the answer is Go; on changes, revise the plan as they "
      "asked and call this again. It publishes nothing: where a diagram would "
      "explain the plan better than prose and `artifact` is offered, publish "
      "one first.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "title": {
        "type": "string",
        "description":
            "A short title for the plan, shown in the chat and "
            "on the question.",
      },
    },
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final args = presentPlanArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* toolRejected(
        call,
        'The $presentPlanToolName tool takes no required arguments; "title" '
        "is an optional string.",
      );
      return;
    }
    yield toolCalled(call, args.title ?? planFileName);
    final plan = await readPlan(turn);
    final missing = _planMissing(plan);
    if (missing != null) {
      yield toolFailed(call, missing);
      return;
    }
    // Emitted before it is awaited, for the same reason an approval is: the
    // panel is where the verdict comes from. The verdict is then the tool's
    // result, so the model reads it as the outcome of presenting rather than
    // as the user's prose. The questions ride as the request's document —
    // what another device reads the call's arguments back out of — since the
    // call's own arguments name a title, not a question.
    final request = AskRequest(
      id: call.id,
      questions: [planApprovalQuestion(args.title)],
      argumentsJson: planApprovalQuestionsJson(args.title),
    );
    yield QuestionRequestEvent(request);
    final answers = await turn.answer(request);
    final verdict = planVerdict(answers.firstOrNull);
    // Go takes the first task, so the work starts from what was approved
    // with no call spent asking for it.
    final first = answers.firstOrNull == "go" ? _nextToTake(plan!) : null;
    yield toolOk(
      call,
      first == null
          ? verdict
          : "$verdict\n\nNow taken — ${await _take(turn, plan!, first)}",
    );
  }
}
