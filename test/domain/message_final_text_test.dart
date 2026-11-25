import "package:entoli_core/model/models.dart";
import "package:flutter_test/flutter_test.dart";

Message _reply(List<MessagePart> parts) => Message(
  id: "m",
  role: MessageRole.assistant,
  createdAt: DateTime(2026),
  parts: parts,
);

const _call = MessagePart.toolCall(
  toolCall: ToolCall(id: "c", name: "bash"),
);

void main() {
  test("is the text after the last tool call", () {
    final reply = _reply([
      const MessagePart.text(text: "Let me look."),
      _call,
      const MessagePart.text(text: "Found it."),
      const MessagePart.text(text: "It is fixed."),
    ]);
    expect(reply.finalText, "Found it.\nIt is fixed.");
  });

  test("is all of it where no call came before", () {
    final reply = _reply([const MessagePart.text(text: "Hello.")]);
    expect(reply.finalText, "Hello.");
  });

  test("is all of it where nothing was said after the last call", () {
    final reply = _reply([const MessagePart.text(text: "Let me look."), _call]);
    expect(reply.finalText, "Let me look.");
  });
}
