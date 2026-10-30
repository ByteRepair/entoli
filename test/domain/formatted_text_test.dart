import "package:agent_chat/domain/formatted_text.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("formattedTextOf", () {
    test("strips inline emphasis and keeps the words", () {
      expect(
        formattedTextOf("here is **bold** and *italic*"),
        "here is bold and italic",
      );
    });

    test("keeps a link's text and drops its target", () {
      expect(
        formattedTextOf("See [the docs](https://example.com)."),
        "See the docs.",
      );
    });

    test("separates a heading from its paragraph", () {
      expect(
        formattedTextOf("# Heading\n\nhere is **bold** code"),
        "Heading\nhere is bold code",
      );
    });

    test("keeps fenced code as it is written, once", () {
      expect(
        formattedTextOf("read this:\n\n```python\nprint(1)\n```"),
        "read this:\nprint(1)",
      );
    });

    test("reads a list as its items, one per line", () {
      expect(formattedTextOf("- one\n- two"), "one\ntwo");
    });

    // What was said, not the entities the HTML layer would encode it as.
    test("keeps quotes and ampersands as the characters they encode", () {
      expect(
        formattedTextOf('He said "hello" & <left> — quoted'),
        'He said "hello" & <left> — quoted',
      );
    });

    test("decodes an entity the markdown itself carried", () {
      expect(formattedTextOf("call it &quot;done&quot;"), 'call it "done"');
    });
  });

  group("formattedHtmlOf", () {
    test("renders blocks and inline styles as HTML", () {
      expect(
        formattedHtmlOf("# Title\n\nhere is **bold** and [it](https://x.org)"),
        '<h1>Title</h1><p>here is <strong>bold</strong> and <a href="https://x.org">it</a></p>',
      );
    });

    // The renderer shows HTML the model wrote as the characters it is.
    test("escapes what was said rather than passing HTML through", () {
      expect(
        formattedHtmlOf('a <div> & "b"'),
        '<p>a &lt;div&gt; &amp; "b"</p>',
      );
    });

    test("styles code inline, since a word processor reads no stylesheet", () {
      expect(
        formattedHtmlOf("```\nx\n```"),
        startsWith('<pre style="font-family:'),
      );
    });
  });

  group("RenderedOutline", () {
    final outline = RenderedOutline.of(
      "## Head\n\n3. three\n4. four\n\n> quoted\n\n| a | b |\n|---|---|\n| c | d |\n\n"
      "see [the  docs](https://e.com)",
    );

    test("reads each rendered paragraph's kind back from the markdown", () {
      expect(outline.blockOf("Head")?.level, 2);
      expect(outline.blockOf("four")?.kind, BlockKind.listItem);
      expect(outline.blockOf("four")?.number, 4);
      expect(outline.blockOf("quoted")?.quoted, isTrue);
      expect(outline.blockOf("a")?.kind, BlockKind.headerCell);
      expect(outline.blockOf("d")?.kind, BlockKind.cell);
      expect(outline.blockOf("nothing"), isNull);
    });

    test("finds a link's target by its words, whitespace folded", () {
      expect(outline.hrefOf("the docs"), "https://e.com");
      expect(outline.hrefOf("docs"), "https://e.com");
    });
  });
}
