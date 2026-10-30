import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/readable_client.dart";

void main() {
  LlmAttachment file(String name, String mime, [int size = 1]) =>
      LlmAttachment(filename: name, mimeType: mime, bytes: Uint8List(size));

  test("an image becomes a line naming it; the rest is left alone", () {
    final notes = file("notes.txt", "text/plain");
    final messages = [
      const LlmMessage(role: LlmRole.user, text: "plain"),
      LlmMessage(
        role: LlmRole.user,
        text: "look",
        attachments: [file("a.png", "image/png"), notes],
      ),
      LlmMessage(
        role: LlmRole.tool,
        toolCallId: "c1",
        text: "made",
        attachments: [file("b.png", "image/png")],
      ),
    ];

    final sent = readable(messages, images: false, pdfs: false);

    expect(identical(sent.first, messages.first), isTrue);
    expect(sent[1].attachments, [notes]);
    expect(sent[1].text, contains("a.png"));
    expect(sent[2].attachments, isEmpty);
    expect(sent[2].toolCallId, "c1");
    expect(sent[2].text, startsWith("made"));
  });

  test("a PDF goes where the endpoint takes one and is named where not", () {
    final spec = file("spec.pdf", "application/pdf");
    final messages = [
      LlmMessage(role: LlmRole.user, text: "read", attachments: [spec]),
    ];

    expect(
      identical(
        readable(messages, images: true, pdfs: true).single,
        messages.single,
      ),
      isTrue,
    );
    final named = readable(messages, images: true, pdfs: false).single;
    expect(named.attachments, isEmpty);
    expect(named.text, contains("spec.pdf"));
    expect(named.text, contains("command"));
  });

  test("PDFs over the budget go oldest first", () {
    final half = pdfBudgetBytes ~/ 2 + 1;
    final messages = [
      LlmMessage(
        role: LlmRole.user,
        text: "one",
        attachments: [file("old.pdf", "application/pdf", half)],
      ),
      LlmMessage(
        role: LlmRole.user,
        text: "two",
        attachments: [file("new.pdf", "application/pdf", half)],
      ),
    ];

    final sent = readable(messages, images: true, pdfs: true);

    expect(sent[0].attachments, isEmpty);
    expect(sent[0].text, contains("old.pdf"));
    expect(identical(sent[1], messages[1]), isTrue);
  });

  test("a PDF's pages are counted off its page objects, not its page tree", () {
    LlmAttachment pdf(String body) => LlmAttachment(
      filename: "a.pdf",
      mimeType: "application/pdf",
      bytes: Uint8List.fromList(body.codeUnits),
    );
    expect(
      pdf("<</Type /Pages>> <</Type/Page>> <</Type\n/Page /X>>").pdfPages,
      2,
    );
    expect(
      pdf("no markers here").pdfPages,
      1,
      reason: "one in a compressed stream is guessed at by size",
    );
  });
}
