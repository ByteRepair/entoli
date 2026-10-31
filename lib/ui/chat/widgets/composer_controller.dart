import "package:flutter/material.dart";

import "composer_embed.dart";

/// The composer's field, holding typed text and [ComposerEmbed]s together.
///
/// Each embed is one character of [text], a private-use code point the
/// controller hands out and keeps a map from, and [buildTextSpan] draws it as
/// the embed's widget. One field rather than a column of fields and cards, so
/// everything the field already does — the `/` and `@` menus, the shortcuts,
/// paste, undo, the keyboard and its IME — goes on working across an embed
/// without being told about it.
///
/// [text] is the field's and has those characters in it; [message] is what is
/// sent, each embed written out as its markdown. Read [message] wherever the
/// question is what the user is saying.
class ComposerController extends TextEditingController {
  ComposerController({this.readers = const [QuoteEmbed.read]});

  /// What turns a paragraph of a message set through [message] back into an
  /// embed, tried in order.
  final List<EmbedReader> readers;

  /// Every embed handed a character, by its code unit. Not pruned as the text
  /// changes: undo brings a deleted character back, and the embed has to
  /// still be here when it does. [clear] lets them go.
  final Map<int, ComposerEmbed> _embeds = {};
  int _next = _firstCode;

  static const _firstCode = 0xE000;
  static const _lastCode = 0xF8FF;

  /// The embeds in the field, in order.
  List<ComposerEmbed> get embeds => [
    for (final unit in text.codeUnits) ?_embeds[unit],
  ];

  /// The field as runs of typed text and embeds, in order.
  List<Object> _parts() {
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

  /// What is sent: [text] with each embed written out. A block is set apart
  /// by a blank line, which is what keeps a quote from running on into the
  /// line typed under it — markdown reads a line straight after a `>` line as
  /// more of the quote. With no embed in it, it is [text] exactly.
  String get message {
    final parts = _parts();
    if (parts.every((part) => part is String)) return text;
    bool isBlock(int i) =>
        i >= 0 && i < parts.length && parts[i] is ComposerEmbed
        ? (parts[i] as ComposerEmbed).block
        : false;
    final out = StringBuffer();
    var lastBlock = false;
    for (final (i, part) in parts.indexed) {
      final String piece;
      final bool block;
      if (part is ComposerEmbed) {
        piece = part.markdown;
        block = part.block;
      } else {
        var typed = part as String;
        final besideBlock = isBlock(i - 1) || isBlock(i + 1);
        if (besideBlock && typed.trim().isEmpty) continue;
        if (isBlock(i - 1)) typed = typed.replaceFirst(_leadingLines, "");
        if (isBlock(i + 1)) typed = typed.replaceFirst(_trailingLines, "");
        piece = typed;
        block = false;
      }
      if (out.isNotEmpty && (block || lastBlock)) out.write("\n\n");
      out.write(piece);
      lastBlock = block;
    }
    return out.toString();
  }

  static final _leadingLines = RegExp(r"^\s*\n");
  static final _trailingLines = RegExp(r"\n\s*$");

  /// Put [message] in the field, a paragraph a reader claims drawn as its
  /// embed — a message taken back comes back as it was composed. Laid out
  /// the way [append] lays embeds out, so what is typed next goes where it
  /// would have.
  set message(String message) {
    _embeds.clear();
    _next = _firstCode;
    final lines = message.split("\n");
    // Each a line of the field: a typed line or an embed.
    final items = <Object>[];
    var i = 0;
    while (i < lines.length) {
      final embed = _embedAt(lines, i);
      if (embed != null) {
        items.add(embed.$1);
        i = embed.$2;
      } else {
        items.add(lines[i++]);
      }
    }
    final field = <String>[];
    for (final (i, item) in items.indexed) {
      if (item is ComposerEmbed) {
        field.add(_allocate(item));
        if (i == items.length - 1) field.add("");
        continue;
      }
      // The blank line that set a block apart from the text under it is the
      // message's; in the field the text sits on the line under the card.
      final underBlock = i > 0 && items[i - 1] is ComposerEmbed;
      final next = i + 1 < items.length ? items[i + 1] : null;
      if (underBlock && item == "" && next is String) continue;
      field.add(item as String);
    }
    final text = field.join("\n");
    value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// The embed a run of lines from [start] spells and where the run ends, or
  /// null. A paragraph of its own only: a `>` line inside a run of text is
  /// the text's.
  (ComposerEmbed, int)? _embedAt(List<String> lines, int start) {
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

  /// Add [embed] at the end, on a line of its own, and put the caret on the
  /// line under it — where an answer to it is typed. Embeds added with
  /// nothing typed between them stack a blank line apart, the line left for
  /// answering the one above later.
  void append(ComposerEmbed embed) {
    final char = _allocate(embed);
    final typed = text.trimRight();
    final next = typed.isEmpty ? "$char\n" : "$typed\n\n$char\n";
    value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  /// Take [embed] out, with the line break it sat on — and the blank line
  /// that set it apart, where taking it out would leave one heading the field
  /// or doubled.
  void remove(ComposerEmbed embed) {
    final at = text.codeUnits.indexWhere((unit) => _embeds[unit] == embed);
    if (at < 0) return;
    var end = at + 1;
    if (end < text.length && text[end] == "\n") end++;
    final lineStart = at == 0 || text[at - 1] == "\n";
    if (lineStart && end < text.length && text[end] == "\n") end++;
    final removed = end - at;
    int shift(int offset) => offset <= at
        ? offset
        : offset >= end
        ? offset - removed
        : at;
    value = TextEditingValue(
      text: text.replaceRange(at, end, ""),
      selection: selection.isValid
          ? selection.copyWith(
              baseOffset: shift(selection.baseOffset),
              extentOffset: shift(selection.extentOffset),
            )
          : const TextSelection.collapsed(offset: -1),
    );
  }

  /// A character for [embed] that nothing in the field is already: the user
  /// may have pasted one from the same range.
  String _allocate(ComposerEmbed embed) {
    while (_next < _lastCode &&
        (_embeds.containsKey(_next) || text.codeUnits.contains(_next))) {
      _next++;
    }
    final code = _next++;
    _embeds[code] = embed;
    return String.fromCharCode(code);
  }

  @override
  void clear() {
    super.clear();
    _embeds.clear();
    _next = _firstCode;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!text.codeUnits.any(_embeds.containsKey)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final children = <InlineSpan>[];
    void typed(int start, int end) {
      if (start >= end) return;
      if (composing.isCollapsed ||
          composing.end <= start ||
          composing.start >= end) {
        children.add(TextSpan(text: text.substring(start, end)));
        return;
      }
      final from = composing.start.clamp(start, end);
      final to = composing.end.clamp(start, end);
      children.addAll([
        if (from > start) TextSpan(text: text.substring(start, from)),
        TextSpan(
          text: text.substring(from, to),
          style: const TextStyle(decoration: TextDecoration.underline),
        ),
        if (end > to) TextSpan(text: text.substring(to, end)),
      ]);
    }

    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final embed = _embeds[text.codeUnitAt(i)];
      if (embed == null) continue;
      typed(start, i);
      children.add(_span(context, embed));
      start = i + 1;
    }
    typed(start, text.length);
    return TextSpan(style: style, children: children);
  }

  /// A block takes the line's whole width, less a little: the field keeps a
  /// margin for the caret past the end of a line, and a placeholder laid out
  /// at the full width would be clipped by it.
  WidgetSpan _span(BuildContext context, ComposerEmbed embed) {
    final drawn = embed.build(context, () => remove(embed));
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: embed.block
          ? SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: drawn,
              ),
            )
          : drawn,
    );
  }
}
