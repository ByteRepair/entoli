import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/formatting.dart";

void main() {
  test("a cut never leaves half a surrogate pair", () {
    // "a😀b": the emoji is two code units, at 1 and 2.
    const text = "a\u{1F600}b";

    expect(safeCut(text, 2), "a");
    expect(safeCut(text, 3), "a\u{1F600}");
    expect(safeCut(text, 10), text);
    expect(safeCut(text, 0), "");
  });
}
