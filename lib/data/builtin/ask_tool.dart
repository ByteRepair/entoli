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
      "turn. They answer by picking one of the options you offer, or by "
      "typing an answer of their own, which comes back as the answer text. "
      "Do not add an \"other\" option; the panel always offers one.",
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
              "description": "The answers to offer. At least one; the user picks "
                  "exactly one, or types their own.",
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
