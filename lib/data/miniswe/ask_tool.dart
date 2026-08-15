import "dart:convert";

import "../../domain/ask.dart";
import "llm/llm_client.dart";

/// The one tool that runs nothing: the agent puts questions to the user and
/// waits. Offered whether or not there is a shell — a browser cannot run a
/// command, but it can still ask.
const askTool = LlmTool(
  name: askToolName,
  description: "Ask the user one or more questions and wait for their answers. "
      "Use it when the answer is theirs to give — a choice between directions, "
      "a preference, a detail only they know — and guessing would waste the "
      "turn. They answer by picking one of the options you offer, so the "
      "options have to cover the ground.",
  schema: {
    "type": "object",
    "properties": {
      "questions": {
        "type": "array",
        "description": "The questions to put to the user, in the order to ask them.",
        "items": {
          "type": "object",
          "properties": {
            "question": {"type": "string", "description": "The question itself."},
            "summary": {
              "type": "string",
              "description": "Optional context, shown under the question.",
            },
            "options": {
              "type": "array",
              "description": "The answers to offer. At least one; the user picks exactly one.",
              "items": {
                "type": "object",
                "properties": {
                  "label": {"type": "string", "description": "The answer, as the user reads it."},
                  "detail": {"type": "string", "description": "Why this one, in a line."},
                },
                "required": ["label"],
              },
            },
          },
          "required": ["question", "options"],
        },
      },
    },
    "required": ["questions"],
  },
);

/// What the model is told when it called the tool with nothing askable in it.
const askFormatError =
    'The $askToolName tool takes {"questions": [{"question": "...", "options": '
    '[{"label": "..."}]}]}. Every question needs at least one option, because '
    "the user answers by clicking one.";

/// The answers as the model reads them. Every question comes back whether or
/// not it was answered: a model that asked three and got two back has to know
/// which one it is still missing.
String askAnswers(List<AskQuestion> questions, List<String?> answers) {
  final pairs = [
    for (var i = 0; i < questions.length; i++)
      {"question": questions[i].question, "answer": answers.elementAtOrNull(i)},
  ];
  return _pretty.convert({
    "answers": pairs,
    if (pairs.every((pair) => pair["answer"] == null))
      "note": "The user answered nothing. Carry on with what you already have, "
          "or say what you still need and finish the turn — do not ask again.",
  });
}

const _pretty = JsonEncoder.withIndent("  ");
