import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/reaction.dart";
import "package:agent_chat/ui/chat/chat_page.dart";

import "../../harness.dart";

void main() {
  Message said(String id, MessageRole role, String text) => Message(
    id: id,
    role: role,
    createdAt: DateTime(2026),
    parts: [MessagePart.text(text: text)],
  );

  test("a reaction is no row: it shows on what it answers, and the reply "
      "before it is still the newest row", () {
    final reply = said("r", MessageRole.assistant, "Done.");
    final chat = Chat(
      state: makeState("c"),
      messages: [
        said("u", MessageRole.user, "Go."),
        reply,
        reactionTo(reply, Reaction.fire, id: "x", at: DateTime(2026)),
      ],
    );
    final rows = entriesOf(chat).whereType<MessageEntry>().toList();

    expect(rows.map((e) => e.message.id), ["u", "r"]);
    expect(rows.last.last, isTrue);
    expect(rows.last.reactions, ["🔥"]);
  });
}
