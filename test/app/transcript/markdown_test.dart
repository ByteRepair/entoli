import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/transcript/markdown.dart";

void main() {
  test("a paragraph's line ends are spaces, and a hard break a break", () {
    final paragraph =
        MarkdownDocument.parse(
              "Wrapped at\nthe column.  \nThen a break.",
            ).blocks.single
            as ParagraphBlock;
    expect(paragraph.inlines.whereType<TextInline>().map((t) => t.text), [
      "Wrapped at the column.",
      "Then a break.",
    ]);
    expect(paragraph.inlines[1], isA<BreakInline>());
  });

  test("a formula on a line of its own is a formula block, its TeX whole", () {
    final blocks = MarkdownDocument.parse(
      "Before.\n\n\$\$\\int_0^1 x^2\\,dx = \\frac{1}{3}\$\$\n\nAfter.",
    ).blocks;
    expect(blocks, hasLength(3));
    final formula = blocks[1] as FormulaBlock;
    expect(formula.tex, r"\int_0^1 x^2\,dx = \frac{1}{3}");
    expect(formula.written, r"$$\int_0^1 x^2\,dx = \frac{1}{3}$$");
  });

  test("a display formula mid-sentence stays in the sentence", () {
    final paragraph =
        MarkdownDocument.parse(r"So $$x^2$$ it is.").blocks.single
            as ParagraphBlock;
    final formula = paragraph.inlines.whereType<FormulaInline>().single;
    expect(formula.tex, "x^2");
    expect(formula.display, isTrue);
  });

  test("an inline formula keeps what markdown would eat", () {
    final paragraph =
        MarkdownDocument.parse(r"Take $a_b_c$ now.").blocks.single
            as ParagraphBlock;
    expect(paragraph.inlines.whereType<FormulaInline>().single.tex, "a_b_c");
  });

  test("a list item's later blocks sit under it with no marker", () {
    final blocks = MarkdownDocument.parse(
      "- Second\n  1. Nested one\n  2. Nested two",
    ).blocks;
    expect([for (final b in blocks) b.nesting.items.length], [1, 2, 2]);
    expect(blocks[1].nesting.items.first.first, isFalse);
    expect(blocks[1].nesting.items.last.number, 1);
  });
}
