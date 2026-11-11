import "../domain/models.dart";
import "../domain/shell.dart";

/// Space, tab, newline — every break a typed message can hold.
bool isCompletionSpace(int codeUnit) =>
    codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A;

typedef CompletionToken = ({CompletionKind kind, int start, String query});

/// The word the [caret] sits in, when it is a trigger token; none where
/// there is no caret, or a selection. `/` only counts at the very start of a
/// message; `@` counts wherever a word begins. Anything offered here has to
/// dispatch, so this matches `prompt_library.dart`'s patterns — and, before
/// them, that a `!` message goes to the shell, where neither a skill of
/// Entoli's nor an agent means anything.
CompletionToken? completionTokenIn(String text, int? caret) {
  if (shellBypassCommand(text) != null) return null;
  if (caret == null || caret > text.length) return null;

  var start = caret;
  while (start > 0 && !isCompletionSpace(text.codeUnitAt(start - 1))) {
    start--;
  }
  if (start == caret) return null;

  final query = text.substring(start + 1, caret);
  return switch (text[start]) {
    "/" when start == 0 => (
      kind: CompletionKind.skill,
      start: start,
      query: query,
    ),
    "@" => (kind: CompletionKind.agent, start: start, query: query),
    _ => null,
  };
}

/// What of [options] the typed [query] matches: its letters anywhere in the
/// name, case aside.
List<CompletionOption> matchingCompletions(
  List<CompletionOption> options,
  String query,
) {
  if (query.isEmpty) return options;
  final needle = query.toLowerCase();
  return options.where((o) => o.name.toLowerCase().contains(needle)).toList();
}
