import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/text_only_client.dart";

void main() {
  LlmAttachment file(String name, String mime) =>
      LlmAttachment(filename: name, mimeType: mime, bytes: Uint8List(1));

  test("an image becomes a line naming it; the rest is left alone", () {
    final notes = file("notes.txt", "text/plain");
    final messages = [
      const LlmMessage(role: LlmRole.user, text: "plain"),
      LlmMessage(role: LlmRole.user, text: "look", attachments: [file("a.png", "image/png"), notes]),
      LlmMessage(role: LlmRole.tool, toolCallId: "c1", text: "made",
          attachments: [file("b.png", "image/png")]),
    ];

    final sent = withoutImages(messages);

    expect(identical(sent.first, messages.first), isTrue);
    expect(sent[1].attachments, [notes]);
    expect(sent[1].text, contains("a.png"));
    expect(sent[2].attachments, isEmpty);
    expect(sent[2].toolCallId, "c1");
    expect(sent[2].text, startsWith("made"));
  });
}
