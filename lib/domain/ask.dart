import "dart:convert";

import "tool_arg.dart";

/// The tool the agent asks with. Named here rather than beside the schema that
/// defines it, because the chat draws an answered question back out of
/// `conv.jsonl`, and what it has to recognise there is a tool call by this name.
const askToolName = "ask_user";

/// One answer the user can pick.
class AskOption {
  const AskOption({required this.label, String? value, this.detail})
    : answer = value ?? label;

  /// What the user reads on the button.
  final String label;

  /// What the model is told, which is the label unless it gave its options a
  /// machine-readable form of their own.
  final String answer;

  /// A line under the label saying why this one.
  final String? detail;
}

class AskQuestion {
  const AskQuestion({
    required this.question,
    this.summary,
    required this.options,
  });

  final String question;

  /// Context for the question, shown under it.
  final String? summary;

  /// Never empty: a question with nothing to click is not askable, and
  /// [askQuestionsFrom] drops it.
  final List<AskOption> options;
}

/// One `ask_user` call, under the tool call's id — which is what its answers
/// travel back with.
class AskRequest {
  const AskRequest({
    required this.id,
    required this.questions,
    this.argumentsJson,
  });

  final String id;
  final List<AskQuestion> questions;

  /// What [questions] was read out of. Kept so another device can read the
  /// same call the same way — see the sync layer's `SyncAsk`. Nothing on this
  /// device looks at it: the questions are already parsed.
  final String? argumentsJson;

  /// A fresh answer for every question, all of them empty — what the panel
  /// starts from, and what a turn that ended before anyone answered sends.
  List<String?> get unanswered => List.filled(questions.length, null);
}

/// The questions in an `ask_user` call's arguments; empty when there is nothing
/// askable in them.
///
/// Deliberately liberal in what it takes. The arguments are the model's writing,
/// not ours: it may send a batch under `questions` or write a single question
/// out at the top level, and it reaches for whichever word for "the answers" its
/// prompt left in its head. A question put plainly enough to render is worth
/// putting on screen whatever it was called.
List<AskQuestion> askQuestionsFrom(String? argumentsJson) {
  final decoded = decodeArgs(argumentsJson);
  if (decoded == null) return const [];
  final batch = decoded["questions"];
  if (batch is List) return batch.map(_question).nonNulls.toList();
  final one = _question(decoded);
  return one == null ? const [] : [one];
}

/// The answers as the model reads them, and the one place the shape of them is
/// written down — [askAnswersFrom] reads this back. Every question comes back
/// whether or not it was answered: a model that asked three and got two has to
/// know which one it is still missing.
String askAnswers(List<AskQuestion> questions, List<String?> answers) {
  final pairs = [
    for (var i = 0; i < questions.length; i++)
      {"question": questions[i].question, "answer": answers.elementAtOrNull(i)},
  ];
  return const JsonEncoder.withIndent("  ").convert({
    "answers": pairs,
    if (pairs.every((pair) => pair["answer"] == null))
      "note":
          "The user answered nothing. Carry on with what you already have, "
          "or say what you still need and finish the turn — do not ask again.",
  });
}

/// What the user picked, read back out of what the tool returned, in the order
/// the questions were asked. Null where they answered nothing.
List<String?> askAnswersFrom(String? output) {
  final answers = decodeArgs(output)?["answers"];
  if (answers is! List) return const [];
  return [
    for (final answer in answers)
      answer is Map ? _string(answer, const ["answer"]) : null,
  ];
}

AskQuestion? _question(Object? raw) {
  if (raw is! Map) return null;
  final text = _string(raw, const ["question", "prompt", "text", "title"]);
  final options = _options(raw);
  if (text == null || options.isEmpty) return null;
  return AskQuestion(
    question: text,
    summary: _string(raw, const [
      "summary",
      "context",
      "detail",
      "description",
    ]),
    options: options,
  );
}

List<AskOption> _options(Map raw) {
  for (final key in const ["options", "angles", "choices", "answers"]) {
    final list = raw[key];
    if (list is List) return list.map(_option).nonNulls.toList();
  }
  return const [];
}

AskOption? _option(Object? raw) {
  if (raw is String) {
    return raw.trim().isEmpty ? null : AskOption(label: raw.trim());
  }
  if (raw is! Map) return null;
  final label = _string(raw, const [
    "label",
    "title",
    "name",
    "option",
    "answer",
    "value",
  ]);
  if (label == null) return null;
  return AskOption(
    label: label,
    value: _string(raw, const ["value", "query", "answer"]),
    detail: _string(raw, const [
      "detail",
      "rationale",
      "description",
      "reason",
    ]),
  );
}

String? _string(Map raw, List<String> keys) {
  for (final key in keys) {
    final value = raw[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}
