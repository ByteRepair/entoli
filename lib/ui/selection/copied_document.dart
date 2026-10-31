/// What a selection copies, before it is anything in particular: blocks of
/// runs, each knowing what it was on screen. A `CopyFormat` writes it out —
/// HTML for a word processor, markdown for a plain-text target — so the two
/// halves of a copy are two readings of one thing rather than two guesses.
/// See "Selecting a reply, and copying it" in `lib/ui/chat/AGENTS.md`.
library;

import "dart:typed_data";

import "../../domain/formatted_text.dart" show BlockKind;

export "../../domain/formatted_text.dart" show BlockKind;

/// A selection, in reading order.
class CopiedDocument {
  const CopiedDocument(this.blocks);

  final List<CopiedBlock> blocks;

  bool get isEmpty => blocks.every((block) => block.inlines.isEmpty);

  /// This document with every formula that can draw itself drawn: what the
  /// formatted half pastes as a picture. Asynchronous because drawing is.
  Future<CopiedDocument> drawn() async => CopiedDocument([
    for (final block in blocks)
      CopiedBlock(
        block.kind,
        [
          for (final inline in block.inlines)
            switch (inline) {
              CopiedFormula(:final drawing?) => CopiedFormula(
                inline.written,
                display: inline.display,
                picture: await drawing.picture(),
              ),
              _ => inline,
            },
        ],
        level: block.level,
        ordered: block.ordered,
        number: block.number,
        quoted: block.quoted,
        language: block.language,
        sameRow: block.sameRow,
      ),
  ]);
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
  const CopiedFormula(
    this.written, {
    this.display = false,
    this.drawing,
    this.picture,
  });

  /// The TeX as it was written, delimiters and all — the one form every
  /// plain-text place a formula is pasted can read back.
  final String written;

  /// On a line of its own rather than in a sentence.
  final bool display;

  /// What can draw it, where it was on screen.
  final FormulaDrawing? drawing;

  /// It drawn, once [CopiedDocument.drawn] has asked: what a target that
  /// keeps formatting pastes, since none of them can typeset TeX.
  final FormulaPicture? picture;

  @override
  String get source => written;
}

/// A formula on screen, able to draw itself again for a copy.
abstract interface class FormulaDrawing {
  /// Null where it cannot be drawn — gone from the screen since the copy.
  Future<FormulaPicture?> picture();
}

/// A formula drawn in black on nothing, at [width] by [height] logical
/// pixels — the size it was on screen, which is the size it pastes at.
class FormulaPicture {
  const FormulaPicture(this.png, {required this.width, required this.height});

  final Uint8List png;
  final double width;
  final double height;
}

/// What a run's style said, as the formats name it.
enum TextMark { code, bold, italic, strike }
