/// Reads what is selected on screen into a [CopiedDocument].
///
/// The selection API answers in plain text only, so this reads the drawn
/// paragraphs themselves: the spans under a selected range say what was bold,
/// italic, code or a link, a placeholder says where a formula sits, and the
/// reply's markdown says which kind of block each paragraph was — a list item
/// and a paragraph are drawn alike. A block the app draws itself says what it
/// is through a [CopiedBlockScope].
library;

import "dart:math" as math;

import "package:flutter/rendering.dart";

import "../../domain/formatted_text.dart" show RenderedBlock, RenderedOutline;
import "../fonts.dart" show monoFamily;
import "copied_block_scope.dart";
import "copied_document.dart";
import "selectable_formula.dart";

/// One selectable with something selected, as the container sees it.
typedef SelectedFragment = ({
  Selectable selectable,
  String selected,
  bool sameLine,
});

class SelectionReader {
  SelectionReader({required RenderObject? root, required String markdown})
    : _root = root,
      _outline = RenderedOutline.of(markdown),
      _paragraphs = _paragraphsUnder(root);

  final RenderObject? _root;
  final RenderedOutline _outline;
  final List<RenderParagraph> _paragraphs;

  /// [fragments], in the order the selection runs, as a document. A paragraph
  /// split by a formula is several fragments and one block.
  CopiedDocument read(List<SelectedFragment> fragments) {
    final entries = <_Entry>[];
    for (final (:selectable, :selected, :sameLine) in fragments) {
      final paragraph = selectable is RenderSelectableFormula
          ? _paragraphAbove(selectable)
          : _paragraphOf(selectable, selected);
      if (paragraph == null) {
        entries.add(
          _Entry.loose(
            selectable is RenderSelectableFormula
                ? CopiedFormula(
                    selectable.written,
                    display: true,
                    drawing: selectable,
                  )
                : CopiedText(selected),
            sameLine: sameLine,
          ),
        );
        continue;
      }
      final entry = entries.lastOrNull?.paragraph == paragraph
          ? entries.last
          : (entries..add(_Entry(paragraph, sameLine: sameLine))).last;
      if (selectable is RenderSelectableFormula) continue;
      final range = selectable.getSelection()!;
      entry.ranges.add((
        start: math.min(range.startOffset, range.endOffset),
        end: math.max(range.startOffset, range.endOffset),
      ));
    }
    return CopiedDocument([for (final entry in entries) _blockOf(entry)]);
  }

  CopiedBlock _blockOf(_Entry entry) {
    final paragraph = entry.paragraph;
    if (paragraph == null) {
      return CopiedBlock(BlockKind.paragraph, [
        entry.loose!,
      ], sameRow: entry.sameLine);
    }
    final scope = RenderCopiedBlockScope.of(paragraph, _root);
    var block = scope != null
        ? RenderedBlock(scope.kind)
        : _outline.blockOf(_textOf(paragraph)) ??
              RenderedBlock(
                _isMonospace(paragraph) ? BlockKind.code : BlockKind.paragraph,
              );
    // An item picked up from the middle is its words, not an item: the bullet
    // was not part of what was selected.
    final from = entry.ranges
        .map((range) => range.start)
        .fold<int?>(
          null,
          (low, start) => low == null ? start : math.min(low, start),
        );
    if (block.kind == BlockKind.listItem && (from ?? 0) > 0) {
      block = RenderedBlock(BlockKind.paragraph, quoted: block.quoted);
    }
    return CopiedBlock(
      block.kind,
      _inlines(paragraph, entry.ranges, block.kind),
      level: block.level,
      ordered: block.ordered,
      number: block.number,
      quoted: block.quoted,
      language: scope?.language,
      sameRow: entry.sameLine,
    );
  }

  /// The selected stretches of [paragraph] as runs, each in the marks its
  /// style draws it with, and each selected formula where its placeholder
  /// is. Runs that share their marks are one run, so a highlighted code
  /// block is one stretch of text rather than a run per token.
  List<CopiedInline> _inlines(
    RenderParagraph paragraph,
    List<({int start, int end})> ranges,
    BlockKind kind,
  ) {
    final placeholders = <RenderBox>[];
    paragraph.visitChildren((child) => placeholders.add(child as RenderBox));
    bool covered(int offset) =>
        ranges.any((range) => offset >= range.start && offset < range.end);

    final out = <CopiedInline>[];
    var offset = 0;
    var placeholder = 0;
    void visit(InlineSpan span, TextStyle? inherited) {
      final style = inherited?.merge(span.style) ?? span.style;
      if (span is! TextSpan) {
        final formula = placeholder < placeholders.length
            ? _formulaIn(placeholders[placeholder])
            : null;
        if (formula != null && formula.isSelected) {
          out.add(CopiedFormula(formula.written, drawing: formula));
        }
        placeholder++;
        offset++;
        return;
      }
      final text = span.text;
      if (text != null) {
        final buffer = StringBuffer();
        for (var i = 0; i < text.length; i++) {
          if (covered(offset + i)) buffer.write(text[i]);
        }
        offset += text.length;
        if (buffer.isNotEmpty) {
          final href = span.recognizer == null ? null : _outline.hrefOf(text);
          final marks = _marks(style, kind);
          final run = CopiedText(buffer.toString(), marks: marks, href: href);
          if (out.lastOrNull case final CopiedText last
              when last.href == href && _sameMarks(last.marks, marks)) {
            out.last = CopiedText(
              last.text + run.text,
              marks: marks,
              href: href,
            );
          } else {
            out.add(run);
          }
        }
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }

    visit(paragraph.text, null);
    return out;
  }

  static bool _sameMarks(Set<TextMark> a, Set<TextMark> b) =>
      a.length == b.length && a.containsAll(b);

  /// The marks [style] reads as. What the whole block is drawn in is not a
  /// mark: a heading is bold, and a code block monospace, without either
  /// being said again inside it.
  static Set<TextMark> _marks(TextStyle? style, BlockKind kind) {
    final weight = style?.fontWeight?.value ?? 400;
    return {
      if (style?.fontFamily == monoFamily && kind != BlockKind.code)
        TextMark.code,
      if (weight >= 600 &&
          kind != BlockKind.heading &&
          kind != BlockKind.headerCell)
        TextMark.bold,
      if (style?.fontStyle == FontStyle.italic) TextMark.italic,
      if (style?.decoration?.contains(TextDecoration.lineThrough) ?? false)
        TextMark.strike,
    };
  }

  static String _textOf(RenderParagraph paragraph) =>
      paragraph.text.toPlainText(includeSemanticsLabels: false);

  /// Every word of [paragraph] is in the code face: a block the markdown
  /// drew in it with no scope of its own to say so. The root span is the
  /// ambient style, so it is the words that are asked.
  static bool _isMonospace(RenderParagraph paragraph) {
    var words = false;
    var mono = true;
    void visit(InlineSpan span, TextStyle? inherited) {
      final style = inherited?.merge(span.style) ?? span.style;
      if (span is! TextSpan) return;
      if (span.text?.trim().isNotEmpty ?? false) {
        words = true;
        mono &= style?.fontFamily == monoFamily;
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }

    visit(paragraph.text, null);
    return words && mono;
  }

  static List<RenderParagraph> _paragraphsUnder(RenderObject? root) {
    final found = <RenderParagraph>[];
    void visit(RenderObject child) {
      if (child is RenderParagraph) found.add(child);
      child.visitChildren(visit);
    }

    if (root != null) visit(root);
    return found;
  }

  /// The paragraph [selectable] stands for. Every `Text` registers through a
  /// selection container of its own around its paragraph, and that container
  /// reports the paragraph's transform as its own and indexes the paragraph's
  /// text — a formula in it one offset, as its placeholder is — which is what
  /// is matched: both types are private to the framework. The words are not
  /// compared: a container answers a formula as its TeX, where the paragraph
  /// holds a placeholder.
  RenderParagraph? _paragraphOf(Selectable selectable, String selected) {
    final range = selectable.getSelection();
    if (range == null) return null;
    final transform = selectable.getTransformTo(null);
    final end = math.max(range.startOffset, range.endOffset);
    for (final paragraph in _paragraphs) {
      if (paragraph.attached &&
          paragraph.getTransformTo(null) == transform &&
          end <= _textOf(paragraph).length) {
        return paragraph;
      }
    }
    return null;
  }

  /// The paragraph an inline formula sits in; null for one on a line of its
  /// own.
  RenderParagraph? _paragraphAbove(RenderSelectableFormula formula) {
    for (
      RenderObject? node = formula.parent;
      node != null;
      node = node.parent
    ) {
      if (node is RenderParagraph) return node;
      if (identical(node, _root)) return null;
    }
    return null;
  }

  static RenderSelectableFormula? _formulaIn(RenderObject root) {
    if (root is RenderSelectableFormula) return root;
    RenderSelectableFormula? found;
    root.visitChildren((child) => found ??= _formulaIn(child));
    return found;
  }
}

/// One block's worth of selected fragments: a paragraph's ranges, or what a
/// selectable with no paragraph of its own answered.
class _Entry {
  _Entry(this.paragraph, {required this.sameLine}) : loose = null;

  _Entry.loose(CopiedInline this.loose, {required this.sameLine})
    : paragraph = null;

  final RenderParagraph? paragraph;
  final CopiedInline? loose;
  final bool sameLine;
  final ranges = <({int start, int end})>[];
}
