import "dart:math" show max;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";

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

  static const _firstCode = 0xE000;

  /// The embeds in the field, in order.
  List<ComposerEmbed> get embeds => _embeds.isEmpty
      ? const []
      : [for (final unit in text.codeUnits) ?_embeds[unit]];

  /// The field as runs of typed text and embeds, in order. Read on every
  /// keystroke, so a field that has never held an embed is one run.
  List<Object> _parts() {
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
    final lines = message.split("\n");
    final field = <String>[];
    var underEmbed = false;
    for (var i = 0; i < lines.length;) {
      if (_embedAt(lines, i) case (final embed, final end)) {
        field.add(_allocate(embed));
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
    final text = field.join("\n");
    value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Put [said] ahead of what the field holds: a message taken back, above
  /// what was typed since. An embed either side of the join is kept a
  /// paragraph of its own, or the line beside a quote would read as more of
  /// it and its card would not come back.
  void prepend(String said) {
    final typed = message;
    if (said.isEmpty || typed.isEmpty) {
      message = "$said$typed";
      return;
    }
    final apart =
        _isEmbed(said.split(_blankLine).last) ||
        _isEmbed(typed.split(_blankLine).first);
    message = "$said${apart ? "\n\n" : "\n"}$typed";
  }

  static final _blankLine = RegExp(r"\n\s*\n");

  bool _isEmbed(String paragraph) =>
      readers.any((read) => read(paragraph.trim()) != null);

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
    value = _replaced(value, at, end);
  }

  /// Every edit, the field's own included, keeps each block on a line of its
  /// own. A card is most of the field, so a click usually lands the caret
  /// beside one, and what was typed then joined the card's line — sent as
  /// more of the quote. Typed or pasted beside a block, a line break is put
  /// between them; a Backspace or Delete that would join a block to the line
  /// beside it takes the block instead, the way one deletes a letter.
  @override
  set value(TextEditingValue next) => super.value = _blocksApart(value, next);

  TextEditingValue _blocksApart(TextEditingValue was, TextEditingValue next) {
    if (_embeds.isEmpty) return next;
    var edited = next;
    final deleted = was.text.length - next.text.length == 1;
    for (var i = 0; i < edited.text.length; i++) {
      final embed = _embeds[edited.text.codeUnitAt(i)];
      if (embed == null || !embed.block) continue;
      final text = edited.text;
      final joinedBefore = i > 0 && text[i - 1] != "\n";
      final joinedAfter = i + 1 < text.length && text[i + 1] != "\n";
      if (!joinedBefore && !joinedAfter) continue;
      if (deleted) {
        edited = _replaced(edited, i, i + 1);
        i--;
        continue;
      }
      // The caret stays where it was typed: after the text before a block,
      // and after the text after one.
      if (joinedAfter) edited = _replaced(edited, i + 1, i + 1, insert: "\n");
      if (joinedBefore) {
        edited = _replaced(edited, i, i, insert: "\n", caretAfter: false);
        i++;
      }
    }
    return edited;
  }

  /// [value] with [start] to [end] replaced by [insert]. A position inside
  /// the range lands at its end, or at its start where not [caretAfter]; a
  /// position past it moves with the text.
  static TextEditingValue _replaced(
    TextEditingValue value,
    int start,
    int end, {
    String insert = "",
    bool caretAfter = true,
  }) {
    final delta = insert.length - (end - start);
    int shift(int offset) => offset < start
        ? offset
        : offset > end || (offset == end && end > start)
        ? offset + delta
        : caretAfter
        ? start + insert.length
        : start;
    final selection = value.selection;
    final composing = value.composing;
    return TextEditingValue(
      text: value.text.replaceRange(start, end, insert),
      selection: selection.isValid
          ? selection.copyWith(
              baseOffset: shift(selection.baseOffset),
              extentOffset: shift(selection.extentOffset),
            )
          : selection,
      composing: composing.isValid
          ? TextRange(start: shift(composing.start), end: shift(composing.end))
          : composing,
    );
  }

  /// A character for [embed] that nothing in the field is already: the user
  /// may have pasted one from the same range.
  String _allocate(ComposerEmbed embed) {
    final taken = {..._embeds.keys, ...text.codeUnits};
    var code = _firstCode;
    while (taken.contains(code)) {
      code++;
    }
    _embeds[code] = embed;
    return String.fromCharCode(code);
  }

  @override
  void clear() {
    super.clear();
    _embeds.clear();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final parts = _parts();
    if (parts.every((part) => part is String)) {
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
    var start = 0;
    for (final part in parts) {
      if (part is ComposerEmbed) {
        children.add(_span(context, part));
        start++;
        continue;
      }
      final end = start + (part as String).length;
      children.addAll(_typed(start, end, composing));
      start = end;
    }
    return TextSpan(style: style, children: children);
  }

  /// [start] to [end] of [text], the part inside [composing] underlined the
  /// way the field's own span marks what an IME is still composing.
  List<TextSpan> _typed(int start, int end, TextRange composing) {
    if (composing.isCollapsed ||
        composing.end <= start ||
        composing.start >= end) {
      return [TextSpan(text: text.substring(start, end))];
    }
    final from = composing.start.clamp(start, end);
    final to = composing.end.clamp(start, end);
    return [
      if (from > start) TextSpan(text: text.substring(start, from)),
      TextSpan(
        text: text.substring(from, to),
        style: const TextStyle(decoration: TextDecoration.underline),
      ),
      if (end > to) TextSpan(text: text.substring(to, end)),
    ];
  }

  /// A block takes the line's width less the field's caret margin. Laid out
  /// any wider it overflows the line, and the line under it — the one the
  /// caret is put on to answer it — is not laid out at all: the caret is
  /// drawn at the card's right edge instead.
  WidgetSpan _span(BuildContext context, ComposerEmbed embed) {
    final drawn = embed.build(context, () => remove(embed));
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: embed.block ? _LineWide(child: drawn) : drawn,
    );
  }
}

/// As wide as the line it is placed on, less [inset]. A `SizedBox` of
/// infinite width is the whole of the line, and a `LayoutBuilder` cannot
/// answer the intrinsic sizes a field asks its placeholders for.
class _LineWide extends SingleChildRenderObjectWidget {
  const _LineWide({required Widget super.child});

  /// More than the field's caret margin: the caret's width and the gap
  /// before it.
  static const inset = 6.0;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLineWide();
}

class _RenderLineWide extends RenderProxyBox {
  BoxConstraints _inner(BoxConstraints constraints) => BoxConstraints.tightFor(
    width: max(0, constraints.maxWidth - _LineWide.inset),
  );

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(_inner(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(child!.getDryLayout(_inner(constraints)));
}
