import "../../../domain/ask.dart";
import "../../../domain/agent_backend.dart";
import "../llm/llm_client.dart";
import "../templates.dart" show substitute, systemProse;
import "agent_tool.dart";
import "turn.dart";

/// The one tool that runs nothing: the agent puts questions to the user and
/// waits. Offered whether or not there is a shell — a device with none cannot
/// run a command, but it can still ask — and never where nobody is there to
/// answer.
/// The call and its answers are a pair like any other, so a finished chat
/// still shows what was asked and picked.
class AskTool extends AgentTool {
  AskTool(super.offer);

  @override
  ToolGroup? get group => null;

  @override
  String get name => askToolName;

  @override
  bool get offered => offer.caps.ask;

  @override
  String get fragment => "`$askToolName` to put a question to the user";

  @override
  String get section =>
      substitute(systemProse("asking"), {"ask_tool": askToolName});

  @override
  String get description =>
      "Ask the user one or more questions and wait for their answers. "
      "Use it when the answer is theirs to give — a choice between directions, "
      "a preference, a detail only they know — and guessing would waste the "
      "turn. They answer by picking one of the options you offer, or by "
      "typing an answer of their own, which comes back as the answer text. "
      "Do not add an \"other\" option; the panel always offers one.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "questions": {
        "type": "array",
        "description":
            "The questions to put to the user, in the order to ask them.",
        "items": {
          "type": "object",
          "properties": {
            "question": {
              "type": "string",
              "description": "The question itself.",
            },
            "summary": {
              "type": "string",
              "description": "Optional context, shown under the question.",
            },
            "options": {
              "type": "array",
              "description":
                  "The answers to offer. At least one; the user picks "
                  "exactly one, or types their own.",
              "items": {
                "type": "object",
                "properties": {
                  "label": {
                    "type": "string",
                    "description": "The answer, as the user reads it.",
                  },
                  "detail": {
                    "type": "string",
                    "description": "Why this one, in a line.",
                  },
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
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final questions = askQuestionsFrom(call.argumentsJson);
    if (questions.isEmpty) {
      yield* toolRejected(call, askFormatError);
      return;
    }
    yield toolCalled(call);
    final request = AskRequest(
      id: call.id,
      questions: questions,
      argumentsJson: call.argumentsJson,
    );
    // Emitted before it is awaited, for the same reason an approval is: the
    // panel is where the answers come from.
    yield QuestionRequestEvent(request);
    yield toolOk(call, askAnswers(questions, await turn.answer(request)));
  }
}

/// What the model is told when it called the tool with nothing askable in it.
const askFormatError =
    'The $askToolName tool takes {"questions": [{"question": "...", "options": '
    '[{"label": "..."}]}]}. Every question needs at least one option, because '
    "the user answers by clicking one.";
