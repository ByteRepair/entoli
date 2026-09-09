import "package:agent_chat/domain/formatted_text.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("formattedTextOf", () {
    test("strips inline emphasis and keeps the words", () {
      expect(formattedTextOf("here is **bold** and *italic*"), "here is bold and italic");
    });

    test("keeps a link's text and drops its target", () {
      expect(formattedTextOf("See [the docs](https://example.com)."), "See the docs.");
    });

    test("separates a heading from its paragraph", () {
      expect(formattedTextOf("# Heading\n\nhere is **bold** code"),
          "Heading\nhere is bold code");
    });

    test("keeps fenced code as it is written, once", () {
      expect(formattedTextOf("read this:\n\n```python\nprint(1)\n```"),
          "read this:\nprint(1)");
    });

    test("reads a list as its items, one per line", () {
      expect(formattedTextOf("- one\n- two"), "one\ntwo");
    });
  });
}