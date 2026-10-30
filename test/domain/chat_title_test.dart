import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_title.dart";

void main() {
  group("the prompt", () {
    test("carries the message it is naming", () {
      expect(
        titlePrompt("how do I sort a list?"),
        contains("how do I sort a list?"),
      );
    });

    test("a pasted file is cut down before it is paid for", () {
      final prompt = titlePrompt("x" * 5000);

      expect(prompt.length, lessThan(3000));
    });
  });

  group("the answer", () {
    test("is used as it comes when the model does as it was told", () {
      expect(
        cleanTitle("Sorting a list of records by date"),
        "Sorting a list of records by date",
      );
    });

    test("loses the quotes a model wraps it in", () {
      expect(cleanTitle('"Fixing the parser"'), "Fixing the parser");
    });

    test("loses a Title: prefix, a heading marker and a full stop", () {
      expect(cleanTitle("## Title: Fixing the parser."), "Fixing the parser");
    });

    test("is the first line, not the explanation under it", () {
      expect(
        cleanTitle("Fixing the parser\n\nI chose this because..."),
        "Fixing the parser",
      );
    });

    test("is cut to twenty words when the model ignores the limit", () {
      expect(
        cleanTitle(List.filled(30, "word").join(" "))!.split(" "),
        hasLength(20),
      );
    });

    test("is cut by length too, so one long word cannot fill the sidebar", () {
      expect(cleanTitle("y" * 400)!.length, lessThanOrEqualTo(121));
    });

    test("nothing to show is nothing, not an empty title", () {
      expect(cleanTitle("  \n \n"), isNull);
      expect(cleanTitle('""'), isNull);
    });
  });
}
