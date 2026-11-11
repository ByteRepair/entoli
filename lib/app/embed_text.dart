import "dart:math" show max;

/// Something in the composer that is not typed text, as the core sees it:
/// what it stands for in the message, and whether it is a paragraph of its
/// own. How it is drawn is each frontend's.
abstract interface class Embed {
  /// A block sends as a paragraph of its own, with a blank line either side
  /// whatever was typed around it. An inline one sends exactly where it is.
  bool get block;

  /// What this is in the message sent.
  String get markdown;
}

/// The composer's text and its embeds together, with no widget in it: each
/// embed is one character of the text, a private-use code point handed out
/// here and kept in a map, so a field that edits the text edits the embeds
/// with it. Every frontend's field keeps one.
class EmbedText<E extends Embed> {
  EmbedText({required this.readers});

  /// What turns a paragraph of a message back into an embed, tried in order.
  final List<E? Function(String block)> readers;

  /// Every embed handed a character, by its code unit. Not pruned as the text
  /// changes: undo brings a deleted character back, and the embed has to
  /// still be here when it does. [clear] lets them go.
  final Map<int, E> _embeds = {};

  static const _firstCode = 0xE000;

  bool get isEmpty => _embeds.isEmpty;

  E? operator [](int code) => _embeds[code];

  void clear() => _embeds.clear();

  /// The embeds in [text], in order.
  List<E> embedsIn(String text) => _embeds.isEmpty
      ? const []
      : [for (final u in text.codeUnits) ?_embeds[u]];

  /// The embeds in [text] by the code unit standing for each.
  Map<int, E> byCodeIn(String text) => _embeds.isEmpty
      ? const {}
      : {for (final u in text.codeUnits) u: ?_embeds[u]};

  /// [text] as runs of typed text and embeds, in order. Read on every
  /// keystroke, so a field that has never held an embed is one run.
  List<Object> parts(String text) {
    if (_embeds.isEmpty) return [if (text.isNotEmpty) text];
    final parts = <Object>[];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final embed = _embeds[text.codeUnitAt(i)];
      if (embed == null) continue;
      if (i > start) parts.add(text.substring(start, i));
      parts.add(embed);
      start = i + 1;
    }
    if (start < text.length) parts.add(text.substring(start));
    return parts;
  }

  /// Whether the part at [i] of [parts] is a block embed; false off either
  /// end.
  static bool isBlock(List<Object> parts, int i) =>
      i >= 0 && i < parts.length && parts[i] is Embed
      ? (parts[i] as Embed).block
      : false;

  static final _leadingLines = RegExp(r"^\s*\n");
  static final _trailingLines = RegExp(r"\n\s*$");
  static final _blankLine = RegExp(r"\n\s*\n");

  /// What is sent: [text] with each embed written out. A block is set apart
  /// by a blank line, which is what keeps a quote from running on into the
  /// line typed under it — markdown reads a line straight after a `>` line as
  /// more of the quote. With no embed in it, it is [text] exactly.
  String messageOf(String text) {
    final parts = this.parts(text);
    if (parts.every((part) => part is String)) return text;
    final out = StringBuffer();
    var lastBlock = false;
    for (final (i, part) in parts.indexed) {
      final String piece;
      final bool block;
      if (part is Embed) {
        piece = part.markdown;
        block = part.block;
      } else {
        var typed = part as String;
        final besideBlock = isBlock(parts, i - 1) || isBlock(parts, i + 1);
        if (besideBlock && typed.trim().isEmpty) continue;
        if (isBlock(parts, i - 1)) {
          typed = typed.replaceFirst(_leadingLines, "");
        }
        if (isBlock(parts, i + 1)) {
          typed = typed.replaceFirst(_trailingLines, "");
        }
        piece = typed;
        block = false;
      }
      if (out.isNotEmpty && (block || lastBlock)) out.write("\n\n");
      out.write(piece);
      lastBlock = block;
    }
    return out.toString();
  }

  /// The text for [message], a paragraph a reader claims standing for its
  /// embed — a message taken back comes back as it was composed. Laid out
  /// the way [append] lays embeds out, so what is typed next goes where it
  /// would have. Every embed held before is let go.
  String textOf(String message) {
    _embeds.clear();
    final lines = message.split("\n");
    final field = <String>[];
    var underEmbed = false;
    for (var i = 0; i < lines.length;) {
      if (_embedAt(lines, i) case (final embed, final end)) {
        field.add(_allocate(message, embed));
        i = end;
        underEmbed = true;
        continue;
      }
      final line = lines[i++];
      // The blank line that set a block apart from the text under it is the
      // message's; in the field the text sits on the line under the card.
      final separator =
          underEmbed &&
          line.isEmpty &&
          i < lines.length &&
          _embedAt(lines, i) == null;
      if (!separator) field.add(line);
      underEmbed = false;
    }
    // The line under the last card, for the caret.
    if (underEmbed) field.add("");
    return field.join("\n");
  }

  /// The text with [said] ahead of [text]: a message taken back, above what
  /// was typed since. An embed either side of the join is kept a paragraph of
  /// its own, or the line beside a quote would read as more of it and its
  /// card would not come back.
  String prepended(String text, String said) {
    final typed = messageOf(text);
    if (said.isEmpty || typed.isEmpty) return textOf("$said$typed");
    final apart =
        _isEmbed(said.split(_blankLine).last) ||
        _isEmbed(typed.split(_blankLine).first);
    return textOf("$said${apart ? "\n\n" : "\n"}$typed");
  }

  bool _isEmbed(String paragraph) =>
      readers.any((read) => read(paragraph.trim()) != null);

  /// The embed a run of lines from [start] spells and where the run ends, or
  /// null. A paragraph of its own only: a `>` line inside a run of text is
  /// the text's.
  (E, int)? _embedAt(List<String> lines, int start) {
    bool blank(int i) => i < 0 || i >= lines.length || lines[i].trim().isEmpty;
    if (blank(start) || !blank(start - 1)) return null;
    var end = start;
    while (!blank(end)) {
      end++;
    }
    final block = lines.sublist(start, end).join("\n");
    for (final read in readers) {
      if (read(block) case final embed?) return (embed, end);
    }
    return null;
  }

  /// [text] with [embed] at the end on a line of its own, and the caret on
  /// the line under it — where an answer to it is typed. Embeds added with
  /// nothing typed between them stack a blank line apart, the line left for
  /// answering the one above later.
  String appended(String text, E embed) {
    final char = _allocate(text, embed);
    final typed = text.trimRight();
    return typed.isEmpty ? "$char\n" : "$typed\n\n$char\n";
  }

  /// [text] with [embed] taken out, with the line break it sat on — and the
  /// blank line that set it apart, where taking it out would leave one
  /// heading the field or doubled — and [base] and [extent] moved to match.
  /// Null where [embed] is not in it.
  ({String text, int base, int extent})? removed(
    String text,
    E embed, {
    required int base,
    required int extent,
  }) {
    final at = text.codeUnits.indexWhere((unit) => _embeds[unit] == embed);
    if (at < 0) return null;
    var end = at + 1;
    if (end < text.length && text[end] == "\n") end++;
    final lineStart = at == 0 || text[at - 1] == "\n";
    if (lineStart && end < text.length && text[end] == "\n") end++;
    int shift(int offset) =>
        offset <= at ? offset : max(at, offset - (end - at));
    return (
      text: text.replaceRange(at, end, ""),
      base: shift(base),
      extent: shift(extent),
    );
  }

  /// A character for [embed] that nothing in [text] is already: the user
  /// may have pasted one from the same range.
  String _allocate(String text, E embed) {
    final taken = {..._embeds.keys, ...text.codeUnits};
    var code = _firstCode;
    while (taken.contains(code)) {
      code++;
    }
    _embeds[code] = embed;
    return String.fromCharCode(code);
  }
}
