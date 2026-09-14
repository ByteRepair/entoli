import "../../domain/plan.dart";
import "llm/llm_client.dart";

/// The plan tools. Named in `lib/domain/plan.dart` beside the parser, the way
/// `artifactToolName` is, so dispatch and tests read one source.

/// Record a task. One call per task, in the order the work goes, so the plan
/// reads as an order rather than a heap.
const planAddTool = LlmTool(
  name: planAddToolName,
  description: "Add one task to the plan ($planFileName in the workspace). "
      "One call per task, in the order the work goes. The plan is shown to "
      "the user for approval before any of it starts, so a task is a step "
      "they would want to read: what is done, not how.",
  schema: {
    "type": "object",
    "properties": {
      "task": {
        "type": "string",
        "description": "The task, one line — what will be done.",
      },
      "section": {
        "type": "string",
        "description": "Optional heading to file it under. Tasks without one "
            "go under \"$planDefaultSection\".",
      },
    },
    "required": ["task"],
  },
);

/// Take the next task. The mark in the file is the fact; the result is what
/// the model says it is working on.
const planNextTool = LlmTool(
  name: planNextToolName,
  description: "Take the next pending task of the plan and mark it as being "
      "worked on. Answers the task's number, so plan_done can name it. "
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

/// The plan, presented. The card the user opens and the Go/changes question
/// are one call, so the model cannot show one without the other.
const presentPlanTool = LlmTool(
  name: presentPlanToolName,
  description:
      "Present the plan for approval when the last task is recorded. "
      "Publishes the plan as a card the user opens, then asks them: Go, or "
      "request changes. Do not start executing until the answer is Go; on a "
      "request for changes, find out what to adjust, revise the plan, and "
      "call this again with the same artifact_id.",
  schema: {
    "type": "object",
    "properties": {
      "title": {
        "type": "string",
        "description": "A short title for the plan, shown on the card and "
            "the question.",
      },
      "artifact_id": {
        "type": "string",
        "description": "The id returned by an earlier $presentPlanToolName "
            "call. Pass it to update the plan already on the screen rather "
            "than publish a second card.",
      },
    },
  },
);
