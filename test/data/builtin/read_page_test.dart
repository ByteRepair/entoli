import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/tools/file_tools.dart";

void main() {
  // 500 lines of 409 characters each, numbered: ~51,000 tokens by the
  // four-characters estimate, twice the cap.
  final big = [for (var i = 0; i < 500; i++) "$i ${"word " * 80}\n"].join();

  test("a read of the whole file over the cap is the lines that fit, saying "
      "where the next page starts", () {
    final page = readPage(big, path: "big.txt");

    expect(page.refused, isNull);
    final lines = page.text.split("\n");
    final shown = lines.where((l) => RegExp(r"^\d+: ").hasMatch(l)).length;
    expect(shown, greaterThan(0));
    expect(page.text.length, lessThanOrEqualTo(readTokenCap * 4 + 400));
    expect(lines.first, startsWith("1: 0 word"));
    expect(
      page.text,
      contains(
        "[Truncated: PARTIAL view — big.txt: showing lines 1-$shown of 500 "
        "total (",
      ),
    );
    expect(
      page.text,
      contains(
        "tokens, cap $readTokenCap). Call read with offset=${shown + 1} "
        "limit=$shown for the next page",
      ),
    );
    expect(
      page.text,
      endsWith(
        "Do NOT answer from this page alone if the answer may be further "
        "in the file.]",
      ),
    );
  });

  test("a range over the cap is refused, in Claude Code's words", () {
    final page = readPage(big, path: "big.txt", offset: 2, limit: 400);

    expect(page.text, isEmpty);
    expect(
      page.refused,
      matches(
        RegExp(
          r"^File content \(\d+ tokens\) exceeds maximum allowed tokens "
          r"\(25000\)\. Use offset and limit parameters to read specific "
          r"portions of the file, or search for specific content instead of "
          r"reading the whole file\.$",
        ),
      ),
    );
  });

  test("with no limit a read stops at 2,000 lines and says where the rest "
      "starts", () {
    final long = [for (var i = 1; i <= 2100; i++) "$i\n"].join();

    final page = readPage(long, path: "long.txt");

    expect(page.text, startsWith("1: 1\n"));
    expect(page.text, contains("2000: 2000\n"));
    expect(page.text, isNot(contains("2001: ")));
    expect(
      page.text,
      endsWith(
        "[Showing lines 1-2000 of 2100. Call read with offset=2001 for the "
        "rest.]\n",
      ),
    );
    // A limit the model set is its own, and says nothing more.
    expect(
      readPage(long, path: "long.txt", offset: 2001, limit: 100).text,
      allOf(startsWith("2001: 2001\n"), endsWith("2100: 2100\n")),
    );
  });

  test("one line longer than the cap is cut by characters", () {
    final page = readPage("${"x" * 200000}\n", path: "min.js");

    expect(page.refused, isNull);
    expect(
      page.text,
      contains(
        "[Truncated: PARTIAL view — min.js: showing the first "
        "${readTokenCap * 4} of 200001 characters",
      ),
    );
    expect(page.text, contains("cannot be paginated by line"));
  });
}
