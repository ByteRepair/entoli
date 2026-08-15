import "dart:convert";

/// The tool the agent asks with. Named here rather than beside the schema that
/// defines it, because the chat draws an answered question back out of
/// `conv.json`, and what it has to recognise there is a tool call by this name.
const askToolName = "ask_user";

/// One answer the user can pick.
class AskOption {
  const AskOption({required this.label, this.value, this.detail});

  /// What the user reads on the button.
  final String label;

  /// What the model is told when that is not simply the label — a model that
  /// gave its options a machine-readable form gets that form back.
  final String? value;

  /// A line under the label saying why this one.
  final String? detail;

  String get answer => value ?? label;
}

class AskQuestion {
  const AskQuestion({required this.question, this.summary, required this.options});

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
  const AskRequest({required this.id, required this.questions});

  final String id;
  final List<AskQuestion> questions;
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
  final decoded = _decode(argumentsJson);
  if (decoded == null) return const [];
  final batch = decoded["questions"];
  if (batch is List) return batch.map(_question).nonNulls.toList();
  final one = _question(decoded);
  return one == null ? const [] : [one];
}

/// What the user picked, read back out of what the tool returned. One entry per
/// question asked, null where they answered nothing.
List<String?> askAnswersFrom(String? output, int count) {
  final answers = _decode(output)?["answers"];
  return [
    for (var i = 0; i < count; i++)
      answers is List && i < answers.length && answers[i] is Map
          ? _string(answers[i] as Map, const ["answer"])
          : null,
  ];
}

AskQuestion? _question(Object? raw) {
  if (raw is! Map) return null;
  final text = _string(raw, const ["question", "prompt", "text", "title"]);
  final options = _options(raw);
  if (text == null || options.isEmpty) return null;
  return AskQuestion(
    question: text,
    summary: _string(raw, const ["summary", "context", "detail", "description"]),
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
  if (raw is String) return raw.trim().isEmpty ? null : AskOption(label: raw.trim());
  if (raw is! Map) return null;
  final label = _string(raw, const ["label", "title", "name", "option", "answer", "value"]);
  if (label == null) return null;
  final value = _string(raw, const ["value", "query", "answer"]);
  return AskOption(
    label: label,
    value: value == label ? null : value,
    detail: _string(raw, const ["detail", "rationale", "description", "reason"]),
  );
}

Map<String, dynamic>? _decode(String? source) {
  if (source == null || source.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(source);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

String? _string(Map raw, List<String> keys) {
  for (final key in keys) {
    final value = raw[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}
