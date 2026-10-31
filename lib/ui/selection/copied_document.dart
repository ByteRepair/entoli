/// What a selection copies, before it is anything in particular: blocks of
/// runs, each knowing what it was on screen. A `CopyFormat` writes it out —
/// HTML for a word processor, markdown for a plain-text target — so the two
/// halves of a copy are two readings of one thing rather than two guesses.
/// See "Selecting a reply, and copying it" in `lib/ui/chat/AGENTS.md`.
library;

import "../../domain/formatted_text.dart" show BlockKind;

export "../../domain/formatted_text.dart" show BlockKind;

/// A selection, in reading order.
class CopiedDocument {
  const CopiedDocument(this.blocks);

  final List<CopiedBlock> blocks;

  bool get isEmpty => blocks.every((block) => block.inlines.isEmpty);
}

/// One block on screen: a paragraph, a heading, a list item, a cell, a code
/// block, or a display formula standing on a line of its own.
class CopiedBlock {
  CopiedBlock(
    this.kind,
    this.inlines, {
    this.level = 0,
    this.ordered = false,
    this.number = 1,
    this.quoted = false,
    this.language,
    this.sameRow = false,
  });

  final BlockKind kind;
  final List<CopiedInline> inlines;

  /// A heading's level.
  final int level;

  /// A list item's list is numbered, and this item is [number] in it.
  final bool ordered;
  final int number;

  /// Inside a block quote.
  final bool quoted;

  /// What a code block was fenced as, where it was.
  final String? language;

  /// A cell on the rendered row of the cell before it.
  final bool sameRow;

  bool get isCell => kind == BlockKind.cell || kind == BlockKind.headerCell;

  /// The block's words, formulas as the TeX they were written as.
  String get text => inlines.map((inline) => inline.source).join();
}

/// A stretch of a block.
sealed class CopiedInline {
  const CopiedInline();

  /// What it reads as written: a run's words, a formula's TeX.
  String get source;
}

/// Words drawn in one style, under one link.
final class CopiedText extends CopiedInline {
  const CopiedText(this.text, {this.marks = const {}, this.href});

  final String text;
  final Set<TextMark> marks;
  final String? href;

  @override
  String get source => text;
}

/// A formula, which is selected whole: a part of a drawn formula is no TeX.
final class CopiedFormula extends CopiedInline {
  const CopiedFormula(this.written);

  /// The TeX as it was written, delimiters and all — the one form every
  /// place a formula is pasted can read back.
  final String written;

  @override
  String get source => written;
}

/// What a run's style said, as the formats name it.
enum TextMark { code, bold, italic, strike }
