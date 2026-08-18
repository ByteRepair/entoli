import "package:agent_chat/domain/speech_text.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("speakable", () {
    test("drops a fenced block whole", () {
      expect(
        speakable("Try this:\n```sh\nrm -rf /tmp/x\n```\nThen check it."),
        "Try this:\nThen check it.",
      );
    });

    test("keeps what inline code says, without the backticks", () {
      expect(speakable("Open `main.dart` first."), "Open main.dart first.");
    });

    test("reads a heading as the words in it", () {
      expect(speakable("## What changed"), "What changed");
    });

    test("reads a list as its items", () {
      expect(speakable("- one\n- two"), "one\ntwo");
    });

    test("keeps a link's text and drops its target", () {
      expect(speakable("See [the docs](https://example.com)."), "See the docs.");
    });

    test("strips emphasis without eating the word", () {
      expect(speakable("It is **really** important"), "It is really important");
    });

    test("reads a table as its cells", () {
      expect(
        speakable("| a | b |\n| - | - |\n| 1 | 2 |"),
        "a, b\n1, 2",
      );
    });
  });

  group("SentenceSplitter", () {
    test("hands over a sentence once it is whole", () {
      final splitter = SentenceSplitter();
      expect(splitter.add("The first thing"), isEmpty);
      expect(splitter.add("The first thing is done. And th"),
          ["The first thing is done."]);
      expect(splitter.add("The first thing is done. And then"), isEmpty);
    });

    test("does not split a decimal or a file name", () {
      final splitter = SentenceSplitter();
      expect(splitter.add("The version is 1.2.3 and the file is main.dart"), isEmpty);
    });

    test("ends a sentence at a line break", () {
      final splitter = SentenceSplitter();
      expect(splitter.add("A heading of sorts\nand the rest"), ["A heading of sorts"]);
    });

    test("flushes the tail once nothing more is coming", () {
      final splitter = SentenceSplitter();
      splitter.add("Done. Nearly");
      expect(splitter.flush(), "Nearly");
      expect(splitter.flush(), "");
    });

    test("starts over when the text is a different one", () {
      final splitter = SentenceSplitter();
      splitter.add("The first reply is here. More");
      expect(splitter.add("A second reply entirely. Yes"),
          ["A second reply entirely."]);
    });

    test("breaks a run-on rather than holding the first sound back", () {
      final splitter = SentenceSplitter();
      final long = List.filled(80, "word").join(" ");
      expect(splitter.add(long), isNotEmpty);
    });
  });

  group("SpeakableText", () {
    // Every prefix, not the whole text: what it keeps between calls is the
    // point of it, so it has to agree with [speakable] at every length a reply
    // is ever looked at.
    void agreesGrowing(String reply) {
      final growing = SpeakableText();
      for (var i = 0; i <= reply.length; i++) {
        final so = reply.substring(0, i);
        expect(growing.of(so), speakable(so), reason: "at $i characters");
      }
    }

    test("says what speakable says, at every length a reply passes through", () {
      agreesGrowing("## What changed\n\n- one\n- two\n\nSee [the docs](x). Done.");
    });

    test("agrees while a fence is open, and once it has closed", () {
      agreesGrowing("Try this:\n```sh\nrm -rf /tmp/x\n```\nThen check it.");
    });

    test("agrees over a table, whose rule line says nothing", () {
      agreesGrowing("| a | b |\n| --- | --- |\n| 1 | 2 |\n\nAfter it.");
    });

    test("starts over when the text is a different one", () {
      final growing = SpeakableText();
      growing.of("The first reply, which was long.");
      expect(growing.of("## A second"), "A second");
    });
  });
}
