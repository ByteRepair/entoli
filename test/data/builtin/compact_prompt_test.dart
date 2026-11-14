import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/compact_prompt.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";

void main() {
  test("a call too big to read keeps its other arguments whole", () {
    final pieces = SummaryPieces([
      LlmMessage(
        role: LlmRole.assistant,
        toolCalls: [
          LlmToolCall(
            id: "c1",
            name: "write",
            argumentsJson: jsonEncode({
              "path": "lib/big.dart",
              "content": "head${"x" * 40000}tail",
            }),
          ),
        ],
      ),
      const LlmMessage(role: LlmRole.tool, toolCallId: "c1", text: "written"),
    ]);

    const lead = LlmMessage(role: LlmRole.user, text: "the summary so far");
    final piece = pieces.next(2000, lead: lead)!;

    expect(pieces.isDone, isTrue);
    final [first, call, result] = piece;
    expect(first, same(lead));
    expect(result.text, "written");
    final args = jsonDecode(call.toolCalls.single.argumentsJson) as Map;
    expect(args["path"], "lib/big.dart");
    final content = args["content"] as String;
    expect(content, startsWith("headxxx"));
    expect(content, endsWith("xxxtail"));
    expect(content, contains("characters were cut from the middle here"));
    expect(estimateTokens(piece), lessThanOrEqualTo(2000));
  });
}
