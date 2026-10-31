import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/quote.dart";

void main() {
  test("a quote sends as a blockquote, its handle a paragraph of its own", () {
    expect(const Quote("one\n\ntwo").markdown, "> one\n>\n> two");
    expect(
      const Quote("said this", handle: "@scout").markdown,
      "> @scout\n>\n> said this",
    );
  });

  test("a blockquote reads back as the quote that wrote it", () {
    for (final quote in const [
      Quote("one\n\ntwo"),
      Quote("said this", handle: "@scout"),
      // A passage that only starts with a handle is still the passage.
      Quote("@scout said this"),
    ]) {
      expect(Quote.tryParse(quote.markdown), quote);
    }
  });

  test("what is not all `>` lines, or quotes nothing, is no quote", () {
    expect(Quote.tryParse("> one\ntwo"), isNull);
    expect(Quote.tryParse(">\n>"), isNull);
    expect(Quote.tryParse("plain"), isNull);
  });
}
