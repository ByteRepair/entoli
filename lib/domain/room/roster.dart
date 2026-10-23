import "../models.dart";
import "../prompt_library.dart"
    show authorFrom, authorKeys, mentionsIn, nameOf, singleAgentMention, PromptLibrary;
import "../shell.dart" show shellBypassCommand;
import "../wired_skill.dart";

/// Who the room can address, and who a message addresses: the project's agent
/// library behind the project's Omada answer. **The one place Omada is
/// decided for routing** — a direct chat is a roster that addresses no one,
/// so every say is the house's and no reply hands off. See "The contract
/// between direct and Omada chats" in `lib/domain/room/AGENTS.md`.
///
/// Read fresh at each use rather than held, so a toggle or a library edit
/// reaches the next dispatch and never rewrites what is already stamped.
class Roster {
  const Roster({required this.omada, required this.library});

  final bool omada;
  final PromptLibrary library;

  /// [name] where the library still knows them — an unknown name is prose,
  /// not an address. Null is the main agent. Not gated on [omada]: a reply a
  /// member wrote is carried on by that member after the toggle went off.
  String? known(String? name) =>
      name == null || library.find(CompletionKind.agent, name) == null ? null : name;

  /// The members [message] addresses, in the order it names them, sigils off
  /// — a user prompt through what composing wrote into its documents, a
  /// member's reply through its text. A command is addressed to no one it
  /// names (`!grep @researcher` runs a command) and neither is a callback
  /// (`/compact` is the house's own turn). A reply never addresses its own
  /// author: left in, every "hello @a, @b and @me" reschedules its writer.
  List<String> mentioned(Message message) {
    if (!omada || _notSaid(message)) return const [];
    return message.role == MessageRole.user
        ? authorKeys(message.documents)
            .map(nameOf)
            .whereType<String>()
            .where((name) => known(name) != null)
            .toList()
        : mentionsIn(message.plainText, library)
            .where((name) => name != nameOf(message.author))
            .toList();
  }

  /// The routing record a say carries, `Message.addressees`: [mentioned],
  /// sigils on — the dialect author stamps and the projection read.
  List<String> addressees(Message message) => [
        for (final member in mentioned(message)) "${CompletionKind.agent.trigger}$member",
      ];

  /// The author a turn opened on [prompt] is stamped with: the one member it
  /// addresses. Never in a direct chat — a label on the house's voice would
  /// claim a member wrote it — and never for a command or a callback.
  String? authorFor(Message prompt) =>
      !omada || _notSaid(prompt) ? null : authorFrom(prompt.documents);

  /// The member who answers [prompt]: the one a user prompt addresses, or the
  /// one a reply hands to by name. Null is the main agent. Not authorship —
  /// [authorFor] is what labels the reply.
  String? answering(Message prompt) {
    if (!omada) return null;
    return prompt.role == MessageRole.assistant
        ? singleAgentMention(prompt.plainText, library)
        : known(nameOf(authorFor(prompt)));
  }

  static bool _notSaid(Message message) => isCommand(message.plainText);
}

/// A `!` command or a callback `/skill` rather than something said: neither
/// addresses anyone, and neither steers a running turn.
bool isCommand(String text) =>
    shellBypassCommand(text) != null || wiredSkillFromText(text) != null;
