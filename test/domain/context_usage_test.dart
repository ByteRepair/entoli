import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";

void main() {
  final at = DateTime.utc(2026, 1, 1);
  ChatState state() => ChatState(id: "c", title: "t", createdAt: at, updatedAt: at);

  ContextUsage usage(int chat, {int? reported}) =>
      ContextUsage(system: 100, tools: 200, profile: 10, chat: chat, reported: reported);

  List<ChatRecord> exchange(String prompt, String reply, ContextUsage context,
          {String? author}) =>
      [
        ChatRecord.message(id: prompt, role: MessageRole.user, createdAt: at),
        ChatRecord.message(
            id: reply, role: MessageRole.assistant, createdAt: at, author: author),
        ChatRecord.turnEnd(messageId: reply, reason: TurnEnd.done, context: context),
      ];

  Map<String?, ContextUsage> contextsOf(List<ChatRecord> records) =>
      chatFrom(state(), records).contexts;

  test("each participant's newest reply stands, the house under null", () {
    final contexts = contextsOf([
      ...exchange("u1", "a1", usage(1000)),
      ...exchange("u2", "a2", usage(3000), author: "@reviewer"),
      ...exchange("u3", "a3", usage(5000)),
    ]);

    expect(contexts.keys, unorderedEquals([null, "@reviewer"]));
    expect(contexts[null]!.chat, 5000);
    expect(contexts["@reviewer"]!.chat, 3000);
  });

  test("a rewind takes the context back to the reply it leaves last", () {
    final contexts = contextsOf([
      ...exchange("u1", "a1", usage(1000)),
      ...exchange("u2", "a2", usage(5000)),
      const ChatRecord.rewind(messageId: "u2"),
    ]);

    expect(contexts[null]!.chat, 1000);
  });

  test("a turn that never closed leaves the one before it standing", () {
    final contexts = contextsOf([
      ...exchange("u1", "a1", usage(1000)),
      ChatRecord.message(id: "u2", role: MessageRole.user, createdAt: at),
      ChatRecord.message(id: "a2", role: MessageRole.assistant, createdAt: at),
    ]);

    expect(contexts[null]!.chat, 1000);
  });

  test("a compaction after the reply stands in for its chat, as an estimate", () {
    final contexts = contextsOf([
      ...exchange("u1", "a1", usage(90000, reported: 100000)),
      const ChatRecord.compaction(upToMessageId: "a1", summary: "s", chatTokens: 800),
    ]);

    expect(contexts[null]!.chat, 800);
    expect(contexts[null]!.reported, isNull);
    expect(contexts[null]!.total, 1110);
  });

  test("a reply after the compaction measures past it", () {
    final contexts = contextsOf([
      ...exchange("u1", "a1", usage(90000)),
      const ChatRecord.compaction(upToMessageId: "a1", summary: "s", chatTokens: 800),
      ...exchange("u2", "a2", usage(1200)),
    ]);

    expect(contexts[null]!.chat, 1200);
  });

  test("the provider's count is the total, split by the estimate", () {
    final context = usage(690, reported: 2000);

    expect(context.estimated, 1000);
    expect(context.share(context.tools), 400);
    expect(context.share(context.chat), 1380);
  });
}
