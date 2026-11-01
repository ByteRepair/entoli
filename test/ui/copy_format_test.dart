import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/selection/copied_document.dart";
import "package:agent_chat/ui/selection/copy_format.dart";

// The two ways a selection is written, over documents built by hand: what
// is drawn is the reader's business and the widget tests', and these pin
// the syntax each format owes a paste target.
void main() {
  String markdown(List<CopiedBlock> blocks) =>
      const MarkdownCopyFormat().write(CopiedDocument(blocks));
  String html(List<CopiedBlock> blocks) =>
      const HtmlCopyFormat().write(CopiedDocument(blocks));

  CopiedBlock p(List<CopiedInline> inlines, {bool quoted = false}) =>
      CopiedBlock(BlockKind.paragraph, inlines, quoted: quoted);
  CopiedText t(String text, [Set<TextMark> marks = const {}]) =>
      CopiedText(text, marks: marks);

  group("markdown", () {
    test("runs keep their syntax, the spaces at either end outside it", () {
      expect(
        markdown([
          p([
            t("a "),
            t("bold ", {TextMark.bold}),
            t("it", {TextMark.italic}),
            t(" and "),
            const CopiedText("a link", href: "https://example.com"),
          ]),
        ]),
        "a **bold** *it* and [a link](https://example.com)",
      );
    });

    test("a code span is fenced past the backticks inside it", () {
      expect(
        markdown([
          p([
            t("a`b", {TextMark.code}),
          ]),
        ]),
        "``a`b``",
      );
      expect(
        markdown([
          p([
            t("`x", {TextMark.code}),
          ]),
        ]),
        "`` `x ``",
      );
    });

    test("a code block keeps its language and outlasts its backticks", () {
      expect(
        markdown([
          CopiedBlock(BlockKind.code, [t("x")], language: "dart"),
        ]),
        "```dart\nx\n```",
      );
      expect(
        markdown([
          CopiedBlock(BlockKind.code, [t("```")]),
        ]),
        "````\n```\n````",
      );
    });

    test("items of one list are a line apart, numbered from their own", () {
      expect(
        markdown([
          CopiedBlock(BlockKind.heading, [t("Title")], level: 2),
          for (final n in [3, 4])
            CopiedBlock(
              BlockKind.listItem,
              [t("item $n")],
              ordered: true,
              number: n,
            ),
          p([t("after")]),
        ]),
        "## Title\n\n3. item 3\n4. item 4\n\nafter",
      );
    });

    test("a table is rows of pipes, a header row with its rule", () {
      expect(
        markdown([
          CopiedBlock(BlockKind.headerCell, [t("a")]),
          CopiedBlock(BlockKind.headerCell, [t("b")], sameRow: true),
          CopiedBlock(BlockKind.cell, [t("c|d")]),
          CopiedBlock(BlockKind.cell, [t("e")], sameRow: true),
        ]),
        "| a | b |\n|---|---|\n| c\\|d | e |",
      );
    });

    test("a quote marks every line, the gaps between its blocks too", () {
      expect(
        markdown([
          p([t("one")], quoted: true),
          p([t("two")], quoted: true),
        ]),
        "> one\n>\n> two",
      );
    });

    test("a formula is its TeX as written", () {
      expect(
        markdown([
          p([t("so "), const CopiedFormula(r"$x^2$")]),
          p([const CopiedFormula(r"$$\frac{a}{b}$$")]),
        ]),
        "so \$x^2\$\n\n\$\$\\frac{a}{b}\$\$",
      );
    });
  });

  group("html", () {
    test("runs are tags, and what was written is escaped", () {
      expect(
        html([
          p([
            t("<div> "),
            t("bold", {TextMark.bold}),
            const CopiedFormula(r"$a<b$"),
          ]),
        ]),
        r"<p>&lt;div&gt; <b>bold</b>$a&lt;b$</p>",
      );
    });

    test("items are grouped back into their list, numbered from theirs", () {
      expect(
        html([
          CopiedBlock(BlockKind.listItem, [t("x")], ordered: true, number: 2),
          p([t("y")]),
        ]),
        '<ol start="2"><li>x</li></ol><p>y</p>',
      );
    });

    test("a code block keeps its lines", () {
      expect(
        html([
          CopiedBlock(BlockKind.code, [t("a\nb")]),
        ]),
        matches(RegExp(r"^<pre[^>]*>a\nb</pre>$")),
      );
    });
  });
}
