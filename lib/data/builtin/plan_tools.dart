import "../../domain/plan.dart";
import "llm/llm_client.dart";

/// The plan tools. Named in `lib/domain/plan.dart` beside the parser, the way
/// `artifactToolName` is, so dispatch and tests read one source.

/// Record a task. One call per task, in the order the work goes, so the plan
/// reads as an order rather than a heap.
const planAddTool = LlmTool(
  name: planAddToolName,
  description: "Add one task to the plan ($planFileName in the workspace). "
      "One call per task, in the order the work goes. The user reads every "
      "task and its details before approving, and $planNextToolName hands "
      "the details back when the task is taken, so write them to be worked "
      "from: the approach, the files or parts touched, decisions and risks, "
      "and how the result will be checked.",
  schema: {
    "type": "object",
    "properties": {
      "task": {
        "type": "string",
        "description": "The task's title, one line — what will be done.",
      },
      "details": {
        "type": "string",
        "description": "The plan for this task, in markdown: how it will be "
            "done, what it touches, and how it will be verified.",
      },
      "section": {
        "type": "string",
        "description": "Optional heading to file it under. Tasks without one "
            "go under \"$planDefaultSection\".",
      },
    },
    "required": ["task", "details"],
  },
);

/// Take the next task. The mark in the file is the fact; the result is what
/// the model says it is working on.
const planNextTool = LlmTool(
  name: planNextToolName,
  description: "Take the next pending task of the plan and mark it as being "
      "worked on. Answers the task's number, so plan_done can name it, and "
      "the plan written for it. "
      "\"All tasks done.\" when nothing is left.",
  schema: {"type": "object", "properties": {}},
);

/// Finish the task plan_next took, or one the model names otherwise.
const planDoneTool = LlmTool(
  name: planDoneToolName,
  description: "Mark a task of the plan done: the one $planNextToolName last "
      "answered, by number, or by naming enough of the task's text to "
      "identify it.",
  schema: {
    "type": "object",
    "properties": {
      "task": {
        "type": "string",
        "description": "The task's number as $planNextToolName reported it, "
            "or the start of its text.",
      },
    },
    "required": ["task"],
  },
);

/// The plan, presented: drawn in the chat with the Go/changes question under
/// it, one call, so the model cannot show it without asking about it.
const presentPlanTool = LlmTool(
  name: presentPlanToolName,
  description:
      "Present the plan for approval when the last task is recorded. The "
      "chat shows every task with its details, then asks the user: Go, or "
      "type the changes they want. Do not start executing until the answer "
      "is Go; on changes, revise the plan as they asked and call this "
      "again. It publishes nothing: where a diagram would explain "
      "the plan better than prose and `artifact` is offered, publish one "
      "first.",
  schema: {
    "type": "object",
    "properties": {
      "title": {
        "type": "string",
        "description": "A short title for the plan, shown in the chat and "
            "on the question.",
      },
    },
  },
);
