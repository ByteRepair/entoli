// The room's tools: the roster, how a participant of an Omada room learns
// who is in it, and `end_turn`, how a member says nothing.
// The room contract names handles (`@name`); this is the model's way of
// reading the roster, from the project's agent library rather than the room
// contract's prose.
import "../../domain/end_turn.dart";
import "../../domain/models.dart" show CompletionKind;
import "../../domain/prompt_library.dart";
import "llm/llm_client.dart";

export "../../domain/end_turn.dart" show endTurnToolName;

/// A member's way to say nothing: a reply is a message, and a model given
/// only messages writes one — a thank-you, an "all set" — that hands the
/// room another turn. Offered on member turns only: the house answers what
/// nobody else was asked, so it always has something to say.
const endTurnTool = LlmTool(
  name: endTurnToolName,
  description: "End your turn without replying. Nothing is shown to the user "
      "or the other members, and no one is handed a turn. Call it when the "
      "message was not addressed to you, or when your reply would only "
      "thank, agree, or say you are ready. Never call it when the user "
      "addressed you: answer them.",
  schema: {
    "type": "object",
    "properties": {
      "reason": {
        "type": "string",
        "description": "Why you are not replying, in one short sentence. "
            "Kept in the log, not shown.",
      },
    },
  },
);

const listParticipantsToolName = "list_participants";

const listParticipantsTool = LlmTool(
  name: listParticipantsToolName,
  description: "List this room's participants: each member's handle (with the "
      "@, ready to mention in a reply to hand work to them) and their short "
      "description.",
  schema: {"type": "object", "properties": {}},
);

/// The roster as the tool answers it: one line per member, the handle with
/// its sigil on and the description as written. A member with no description
/// is the handle alone. An empty roster answers rather than failing — the
/// room is in force however few members it defines.
///
/// The set is what a mention can reach — every agent in the library, the
/// `user-invocable: false` ones included, mention resolution ignoring the
/// flag the way the @ menu does not.
String participantsListing(Iterable<PromptDocument> members) {
  final sigil = CompletionKind.agent.trigger;
  final lines = [
    for (final member in members)
      switch (member.description?.trim()) {
        null || "" => "$sigil${member.name}",
        final description => "$sigil${member.name} — $description",
      },
  ];
  return lines.isEmpty
      ? "The room has no members: there is no one to hand work to by handle, "
          "so every say is answered by the main agent."
      : lines.join("\n");
}
