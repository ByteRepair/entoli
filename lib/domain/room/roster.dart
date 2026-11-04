import "../agent_definition.dart" show athena;
import "../models.dart";
import "../reaction.dart";
import "../prompt_library.dart"
    show authorKeys, mentionsIn, nameOf, PromptLibrary;
import "../shell.dart" show shellBypassCommand;
import "../wired_skill.dart";

/// Who is in the room, and who a message addresses. A room is a list of
/// participants: a direct chat holds [athena] alone, an Omada chat every
/// agent in the project's library. A say addressing a participant goes to
/// them; one addressing nobody goes to Athena, the default route; a mention of
/// an
/// agent who is not in the room is the speaker's to delegate to, not an
/// address. **The one place routing is decided.** See "The room and its
/// participants" in `lib/domain/room/AGENTS.md`.
///
/// Read fresh at each use rather than held, so a toggle or a library edit
/// reaches the next dispatch and never rewrites what is already stamped.
class Roster {
  const Roster({required this.omada, required this.library});

  /// Whether the room holds the whole library or Athena alone.
  final bool omada;
  final PromptLibrary library;

  bool _inRoom(String name) =>
      name == athena ||
      omada && library.find(CompletionKind.agent, name) != null;

  /// The participants [message] addresses, in the order it names them,
  /// sigils off. A user's say addresses those its documents name, or
  /// Athena where it names nobody in the room — a command and a callback
  /// included, which only the default route runs. A reply hands to
  /// the participants its text names, never its own author: left in, every
  /// "hello @a, @b and @me" reschedules its writer. A reaction addresses
  /// whoever wrote what it reacts to.
  List<String> mentioned(Message message) {
    if (message.role != MessageRole.user) {
      final author = nameOf(message.author);
      return [
        for (final name in mentionsIn(message.plainText, library))
          if (name != author && _inRoom(name)) name,
      ];
    }
    if (_notSaid(message)) return const [athena];
    final named = [
      for (final name in _keysOf(message).map(nameOf).whereType<String>())
        if (_inRoom(name)) name,
    ];
    return named.isEmpty ? const [athena] : named;
  }

  /// The routing record a say carries, `Message.addressees`: [mentioned],
  /// sigils on — the dialect author stamps and the projection read.
  List<String> addressees(Message message) => [
    for (final name in mentioned(message))
      "${CompletionKind.agent.trigger}$name",
  ];

  /// The participant who answers [prompt]: the first it addresses, or
  /// Athena where it addresses no one — a reply naming nobody.
  String answering(Message prompt) => mentioned(prompt).firstOrNull ?? athena;

  /// The participant keys a user's say addresses, sigils on: a reaction's
  /// author, or what composing wrote into its documents.
  static List<String> _keysOf(Message say) {
    final reaction = say.reaction;
    if (reaction == null) return authorKeys(say.documents);
    return [?reaction.author];
  }

  static bool _notSaid(Message message) => isCommand(message.plainText);
}

/// A `!` command or a callback `/skill` rather than something said: neither
/// addresses anyone, and neither steers a running turn.
bool isCommand(String text) =>
    shellBypassCommand(text) != null || wiredSkillFromText(text) != null;
