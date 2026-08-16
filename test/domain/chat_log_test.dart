import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";

void main() {
  final at = DateTime.utc(2026, 1, 1);

  ChatRecord message(String id, [MessageRole role = MessageRole.user]) =>
      ChatRecord.message(id: id, role: role, createdAt: at);

  ChatRecord part(String message, int index, String text) =>
      ChatRecord.part(messageId: message, index: index, part: MessagePart.text(text: text));

  String textOf(Message m) => m.plainText;

  test("replay folds messages and their parts back in order", () {
    final messages = replay([
      message("m1"),
      part("m1", 0, "hello"),
      message("m2", MessageRole.assistant),
      part("m2", 0, "hi"),
      ChatRecord.turnEnd(messageId: "m2", reason: TurnEnd.done),
    ]);

    expect(messages, hasLength(2));
    expect(messages[0].role, MessageRole.user);
    expect(textOf(messages[0]), "hello");
    expect(messages[1].role, MessageRole.assistant);
    expect(textOf(messages[1]), "hi");
  });

  test("a part written again at the same index supersedes it", () {
    final messages = replay([
      message("m1", MessageRole.assistant),
      part("m1", 0, "par"),
      part("m1", 0, "partial"),
      part("m1", 0, "partial answer"),
    ]);

    expect(messages.single.parts, hasLength(1));
    expect(textOf(messages.single), "partial answer");
  });

  test("supersession reaches a part that is no longer last", () {
    // What closing a thinking block looks like: the block is timed after a
    // tool call has already landed behind it.
    final messages = replay([
      message("m1", MessageRole.assistant),
      ChatRecord.part(
          messageId: "m1", index: 0, part: const MessagePart.reasoning(text: "hmm")),
      part("m1", 1, "and so"),
      ChatRecord.part(
          messageId: "m1",
          index: 0,
          part: const MessagePart.reasoning(text: "hmm", durationMs: 1200)),
    ]);

    final reasoning = messages.single.parts.first as ReasoningPart;
    expect(reasoning.durationMs, 1200);
    expect(messages.single.parts, hasLength(2));
  });

  group("growing text", () {
    test("an append lands on the end of the part it names", () {
      final messages = replay([
        message("m1", MessageRole.assistant),
        part("m1", 0, "one"),
        const ChatRecord.append(messageId: "m1", index: 0, text: " two"),
        const ChatRecord.append(messageId: "m1", index: 0, text: " three"),
      ]);

      expect(textOf(messages.single), "one two three");
    });

    test("an append on a thinking block keeps how long it took", () {
      final messages = replay([
        message("m1", MessageRole.assistant),
        const ChatRecord.part(
            messageId: "m1", index: 0, part: MessagePart.reasoning(text: "hm", durationMs: 40)),
        const ChatRecord.append(messageId: "m1", index: 0, text: "mm"),
      ]);

      final block = messages.single.parts.single as ReasoningPart;
      expect(block.text, "hmmm");
      expect(block.durationMs, 40);
    });

    test("an append naming a part that cannot hold text is ignored", () {
      final messages = replay([
        message("m1", MessageRole.assistant),
        const ChatRecord.part(
            messageId: "m1",
            index: 0,
            part: MessagePart.toolCall(toolCall: ToolCall(id: "c1", name: "bash"))),
        const ChatRecord.append(messageId: "m1", index: 0, text: "nope"),
      ]);

      expect(messages.single.parts.single, isA<ToolCallPart>());
    });

    // What decides between an append and writing the part again.
    test("only growth is written as a piece; anything else goes whole", () {
      expect(
          textGrownFrom(
              const MessagePart.text(text: "one"), const MessagePart.text(text: "one two")),
          " two");
      expect(
          textGrownFrom(
              const MessagePart.text(text: "one"), const MessagePart.text(text: "different")),
          isNull);
      expect(
          textGrownFrom(
              const MessagePart.text(text: "one"), const MessagePart.text(text: "one")),
          isNull);
      // A thinking block being timed as it closes changed more than its text.
      expect(
          textGrownFrom(const MessagePart.reasoning(text: "hm"),
              const MessagePart.reasoning(text: "hm", durationMs: 12)),
          isNull);
      expect(
          textGrownFrom(const MessagePart.reasoning(text: "hm"),
              const MessagePart.reasoning(text: "hmmm")),
          "mm");
      // So did one being signed, and one belonging to another response.
      expect(
          textGrownFrom(const MessagePart.reasoning(text: "hm"),
              const MessagePart.reasoning(text: "hmmm", signature: "sig")),
          isNull);
      expect(
          textGrownFrom(const MessagePart.text(text: "one", responseId: "r1"),
              const MessagePart.text(text: "one two", responseId: "r2")),
          isNull);
      expect(
          textGrownFrom(const MessagePart.text(text: "one", responseId: "r1"),
              const MessagePart.text(text: "one two", responseId: "r1")),
          " two");
    });

    test("an append keeps what the part it lands on already carried", () {
      final messages = replay([
        message("m1", MessageRole.assistant),
        const ChatRecord.part(
            messageId: "m1",
            index: 0,
            part: MessagePart.reasoning(text: "hm", signature: "sig", responseId: "r1")),
        const ChatRecord.append(messageId: "m1", index: 0, text: "mm"),
      ]);

      final block = messages.single.parts.single as ReasoningPart;
      expect(block.text, "hmmm");
      expect(block.signature, "sig");
      expect(block.responseId, "r1");
    });
  });

  test("rewind drops its message and everything after it", () {
    final messages = replay([
      message("m1"),
      part("m1", 0, "first"),
      message("m2", MessageRole.assistant),
      part("m2", 0, "answer"),
      message("m3"),
      part("m3", 0, "second"),
      ChatRecord.rewind(messageId: "m2"),
      message("m4", MessageRole.assistant),
      part("m4", 0, "again"),
    ]);

    expect(messages.map(textOf), ["first", "again"]);
  });

  test("records naming nothing are skipped rather than thrown on", () {
    final messages = replay([
      part("gone", 0, "orphan"),
      message("m1"),
      part("m1", 4, "past the end"),
      part("m1", 0, "kept"),
      ChatRecord.rewind(messageId: "never"),
    ]);

    expect(messages.single.parts, hasLength(1));
    expect(textOf(messages.single), "kept");
  });

  test("a record survives the round trip through JSON", () {
    final records = [
      message("m1"),
      part("m1", 0, "hello"),
      const ChatRecord.part(
          messageId: "m1",
          index: 1,
          part: MessagePart.reasoning(text: "thinking", durationMs: 30)),
      const ChatRecord.append(messageId: "m1", index: 0, text: " more"),
      ChatRecord.turnEnd(messageId: "m1", reason: TurnEnd.aborted),
      ChatRecord.rewind(messageId: "m1"),
    ];

    final back = records
        .map((r) => ChatRecord.fromJson(
            jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>))
        .toList();

    expect(back, records);
  });

  test("recordsOf writes a chat out as the log it would have", () {
    final chat = Chat(
      state: ChatState(id: "c1", title: "t", createdAt: at, updatedAt: at),
      messages: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: at,
          parts: const [MessagePart.text(text: "hello")],
        ),
      ],
    );

    expect(replay(recordsOf(chat.messages)), chat.messages);
  });
}
