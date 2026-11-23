// Pasted text — usually a model's reply — read as Bot Avatar definitions. A
// port of the Open Bot Avatar editor's `parseImport.ts` (MIT).
import "dart:convert";

import "definition.dart";

sealed class BotAvatarImport {
  const BotAvatarImport(this.notes);

  /// What the reader did to the text on the way, said honestly.
  final List<String> notes;

  /// Read [text]: the JSON inside a code fence, or between the first
  /// bracket and the last, or the whole of it — one definition or a list.
  factory BotAvatarImport.parse(String text) {
    if (text.trim().isEmpty) {
      return const BotAvatarImportFailed(
        ["Nothing to import yet."],
        ["Paste the JSON a model returned for the avatar."],
        [],
      );
    }
    final (json, notes) = _extract(text);
    Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException catch (e) {
      return BotAvatarImportFailed(
        ["Not valid JSON: ${e.message}"],
        _syntaxHints(json),
        notes,
      );
    }
    final items = data is List ? data : [data];
    if (items.isEmpty) {
      return BotAvatarImportFailed(
        const ["The list is empty."],
        const ["Paste one definition object, or a list of them."],
        notes,
      );
    }
    final values = <BotAvatarDefinition>[];
    final errors = <String>[];
    for (var i = 0; i < items.length; i++) {
      // A whole spec pasted back in is its definition.
      var item = items[i];
      if (item is Map && item.containsKey("definition")) {
        item = item["definition"];
      }
      switch (BotAvatarDefinition.validate(item)) {
        case BotAvatarValid(:final definition):
          values.add(definition);
        case BotAvatarInvalid(errors: final found):
          final prefix = items.length > 1 ? "Item ${i + 1}: " : "";
          errors.addAll(found.map((e) => "$prefix$e"));
      }
    }
    if (errors.isNotEmpty) {
      return BotAvatarImportFailed(errors, const [
        "Send these errors back to the model that wrote it and ask for a "
            "corrected definition.",
        "Keep geometry only: one body path and the eye pair. Colours and "
            "animation are applied here.",
      ], notes);
    }
    return BotAvatarImported(values, [
      ...notes,
      if (items.length > 1) "Imported ${values.length} definitions.",
    ]);
  }
}

final class BotAvatarImported extends BotAvatarImport {
  const BotAvatarImported(this.definitions, super.notes);
  final List<BotAvatarDefinition> definitions;
}

final class BotAvatarImportFailed extends BotAvatarImport {
  const BotAvatarImportFailed(this.errors, this.hints, super.notes);
  final List<String> errors;
  final List<String> hints;
}

final _fence = RegExp(r"```[a-zA-Z0-9_-]*\s*\n([\s\S]*?)```");

(String, List<String>) _extract(String text) {
  final trimmed = text.trim();
  final fence = _fence.firstMatch(trimmed);
  if (fence != null) {
    final inner = fence[1]!.trim();
    return (
      inner,
      [if (inner != trimmed) "Used the JSON inside the code fence."],
    );
  }
  final first = trimmed.indexOf(RegExp(r"[\[{]"));
  if (first > 0) {
    final close = trimmed[first] == "{" ? "}" : "]";
    final last = trimmed.lastIndexOf(close);
    if (last > first) {
      return (
        trimmed.substring(first, last + 1),
        ["Ignored text outside the JSON."],
      );
    }
  }
  return (trimmed, const []);
}

List<String> _syntaxHints(String source) {
  final s = source.trim();
  return [
    if (RegExp(r",\s*[}\]]").hasMatch(source))
      "Remove trailing commas before } or ].",
    if (RegExp(r"'[^']*'\s*:").hasMatch(source))
      "Use double quotes for keys and strings.",
    if (source.contains("//") || source.contains("/*"))
      "Remove comments — JSON does not allow them.",
    if (!s.endsWith("}") && !s.endsWith("]"))
      "The reply looks cut off; ask the model for the complete definition.",
  ].ifEmpty(const ["Paste the model's reply exactly as returned."]);
}

extension<T> on List<T> {
  List<T> ifEmpty(List<T> fallback) => isEmpty ? fallback : this;
}
