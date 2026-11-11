import "dart:math" show max;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";

import "../../../app/composer.dart" show ComposerText, TextValue;
import "../../../app/embed_text.dart";
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
class ComposerController extends TextEditingController implements ComposerText {
  ComposerController({List<EmbedReader> readers = const [QuoteEmbed.read]})
    : _text = EmbedText<ComposerEmbed>(readers: readers);

  /// The encoding, which is the core's: this is the Flutter field over it.
  final EmbedText<ComposerEmbed> _text;

  @override
  int get embedCount => _text.isEmpty ? 0 : embeds.length;

  @override
  int? get caret => selection.isValid ? selection.baseOffset : null;

  @override
  TextValue get textValue {
    final at = selection.isValid
        ? selection
        : TextSelection.collapsed(offset: text.length);
    return (text: text, start: at.start, end: at.end);
  }

  /// One clock for every field, so two fields never share a revision: the
  /// shell's one field shows whichever page's composer is on screen.
  static var _clock = 0;
  var _revision = ++_clock;
  var _reporting = false;

  @override
  int get revision => _revision;

  /// Every set but a report bumps [revision]: the Flutter field's own
  /// typing does too, which no other field reads.
  @override
  set value(TextEditingValue next) {
    if (!_reporting && next != super.value) _revision = ++_clock;
    super.value = next;
  }

  @override
  void edited(TextValue value) {
    int at(int offset) => offset.clamp(0, value.text.length);
    _reporting = true;
    try {
      this.value = TextEditingValue(
        text: value.text,
        selection: TextSelection(
          baseOffset: at(value.start),
          extentOffset: at(value.end),
        ),
      );
    } finally {
      _reporting = false;
    }
  }

  @override
  void edit(String text, int caret) => value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret),
  );

  /// The embeds in the field, in order.
  List<ComposerEmbed> get embeds => _text.embedsIn(text);

  /// The embeds in the field by the code unit standing for each, for a field
  /// that draws them itself.
  Map<int, ComposerEmbed> get embedsByCode => _text.byCodeIn(text);

  /// What is sent: [text] with each embed written out.
  @override
  String get message => _text.messageOf(text);

  /// Put [message] in the field, a paragraph a reader claims drawn as its
  /// embed, and the caret at the end.
  set message(String message) {
    final text = _text.textOf(message);
    edit(text, text.length);
  }

  /// Put [said] ahead of what the field holds: a message taken back, above
  /// what was typed since.
  @override
  void prepend(String said) {
    final next = _text.prepended(text, said);
    edit(next, next.length);
  }

  /// Add [embed] at the end, on a line of its own, and put the caret on the
  /// line under it.
  void append(ComposerEmbed embed) {
    final next = _text.appended(text, embed);
    edit(next, next.length);
  }

  /// Take [embed] out, with the line break it sat on.
  void remove(ComposerEmbed embed) {
    final valid = selection.isValid;
    final out = _text.removed(
      text,
      embed,
      base: valid ? selection.baseOffset : 0,
      extent: valid ? selection.extentOffset : 0,
    );
    if (out == null) return;
    value = TextEditingValue(
      text: out.text,
      selection: valid
          ? selection.copyWith(baseOffset: out.base, extentOffset: out.extent)
          : selection,
    );
  }

  @override
  void clear() {
    super.clear();
    _text.clear();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final parts = _text.parts(text);
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
    for (final (i, part) in parts.indexed) {
      if (part is ComposerEmbed) {
        children.add(_span(context, part));
        start++;
        continue;
      }
      final end = start + (part as String).length;
      if (end == text.length &&
          part == "\n" &&
          EmbedText.isBlock(parts, i - 1)) {
        children.add(_lineUnder);
      } else {
        children.addAll(_typed(start, end, composing));
      }
      start = end;
    }
    return TextSpan(style: style, children: children);
  }

  /// The line break under the last card, drawn as an invisible word joiner
  /// on the line under it. Drawn as a line break, it left the field's last
  /// line empty, and an empty last line is as tall as the line above it — the
  /// card's — so the caret stood a card's height tall under it. A placeholder
  /// would not do either: under a strut, a line of nothing but one is taller
  /// than a line of text. One character for one, so every offset the field
  /// reads off what is drawn is still one of [text]'s, and nothing of it is in
  /// what is copied or sent. Spaced half a pixel wider than what [_LineWide]
  /// leaves beside a card, it wraps under it.
  static const _lineUnder = TextSpan(
    text: "\u2060",
    style: TextStyle(letterSpacing: _LineWide.slack + 0.5),
  );

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

  /// What a field lays its text out narrower than itself by: the gap before
  /// the caret and the caret's width, `RenderEditable`'s private
  /// `_kCaretGap + cursorWidth` at the composer's default cursor.
  static const _caretMargin = 1.0 + 2.0;

  /// What a line holding a card has left beside it.
  static const slack = 1.0;

  static const inset = _caretMargin + slack;

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
