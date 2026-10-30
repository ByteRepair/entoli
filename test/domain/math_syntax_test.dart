import "package:agent_chat/domain/formatted_text.dart";
import "package:agent_chat/domain/math_syntax.dart";
import "package:flutter_test/flutter_test.dart";
import "package:markdown/markdown.dart" as md;

void main() {
  List<md.Element> formulas(String markdown) {
    final found = <md.Element>[];
    void walk(md.Node node) {
      if (node is! md.Element) return;
      if (mathTags.contains(node.tag)) found.add(node);
      node.children?.forEach(walk);
    }

    parseReply(markdown).forEach(walk);
    return found;
  }

  String? tex(md.Element e) => e.attributes[mathTexAttribute];
  bool block(md.Element e) => e.attributes[mathBlockAttribute] != null;

  test(r"reads $…$ and \(…\) as inline formulas", () {
    final found = formulas(r"where $a_b^2$ and \(c_d\) hold");
    expect(found.map((e) => e.tag), [mathInlineTag, mathInlineTag]);
    expect(found.map(tex), ["a_b^2", "c_d"]);
  });

  test(r"reads $$…$$ on a line of its own as a display block", () {
    final found = formulas(r"$$x$$");
    expect(found.single.tag, mathDisplayTag);
    expect(tex(found.single), "x");
    expect(block(found.single), isTrue);
  });

  // A list marker or a four-space indent inside the formula is TeX, not
  // markdown.
  test("keeps a formula spread over lines whole", () {
    final found = formulas("Before\n\$\$\n- a\n    + b\n\$\$\nafter \$y\$");
    expect(found.map(tex), ["- a\n    + b", "y"]);
    expect(block(found.first), isTrue);
  });

  test(r"reads \[…\] across lines as a display block", () {
    final found = formulas("\\[\n\\frac{1}{2}\n\\]");
    expect(tex(found.single), r"\frac{1}{2}");
    expect(block(found.single), isTrue);
  });

  test("takes an unclosed display formula to the end of the reply", () {
    final found = formulas("\$\$\na\nb");
    expect(tex(found.single), "a\nb");
  });

  test(r"leaves $$…$$ mid-sentence in the sentence", () {
    final found = formulas(r"so $$x^2$$ is it");
    expect(found.single.tag, mathDisplayTag);
    expect(block(found.single), isFalse);
  });

  test("leaves money as prose", () {
    expect(formulas(r"it costs $5 and $10"), isEmpty);
    expect(formulas(r"between $ 5 and 6 $"), isEmpty);
  });

  test("leaves an escaped dollar as prose", () {
    expect(formulas(r"\$x\$"), isEmpty);
  });

  test("copies a formula as the TeX it was written as", () {
    expect(formattedTextOf(r"so $a_b_c$ holds"), r"so $a_b_c$ holds");
    expect(formattedHtmlOf(r"so $a<b$"), r"<p>so $a&lt;b$</p>");
  });
}
