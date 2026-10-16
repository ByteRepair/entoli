// The room's roster: how a participant of an Omada room learns who is in it.
// The room contract names handles (`@name`); this is the model's way of
// reading the roster, from the project's agent library rather than the room
// contract's prose.
import "../../domain/prompt_library.dart";
import "llm/llm_client.dart";

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
  final lines = [
    for (final member in members)
      switch (member.description?.trim()) {
        null || "" => "@${member.name}",
        final description => "@${member.name} — $description",
      },
  ];
  return lines.isEmpty
      ? "The room has no members: there is no one to hand work to by handle, "
          "so every say is answered by the main agent."
      : lines.join("\n");
}
