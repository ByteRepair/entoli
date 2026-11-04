import "../agent_definition.dart" show athena;
import "../models.dart";
import "../reaction.dart";
import "../prompt_library.dart"
    show mentionedAgents, mentionsIn, nameOf, PromptLibrary;
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
  /// sigils off. A user's say addresses those its references name, or
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
    final named = _named(message);
    return named.isEmpty ? const [athena] : named;
  }

  /// Whether [prompt] reached its answerer only by the default route: a
  /// user's say naming no one in the room, a command or a callback
  /// included. Nobody else was asked, so its answerer may not decline it —
  /// declining would leave the user with no answer at all.
  bool byDefault(Message prompt) =>
      prompt.role == MessageRole.user && _named(prompt).isEmpty;

  /// The participants a user's say names, in order: none for a command or a
  /// callback, which addresses no one it names.
  List<String> _named(Message say) => _notSaid(say)
      ? const []
      : [
          for (final name in _namesOf(say))
            if (_inRoom(name)) name,
        ];

  /// The routing record a say carries, `Message.addressees`: [mentioned],
  /// sigils on — the dialect author stamps and the projection read.
  List<String> addressees(Message message) => [
    for (final name in mentioned(message))
      "${CompletionKind.agent.trigger}$name",
  ];

  /// The participant who answers [prompt]: the first it addresses, or
  /// Athena where it addresses no one — a reply naming nobody.
  String answering(Message prompt) => mentioned(prompt).firstOrNull ?? athena;

  /// The participants a user's say addresses, sigils off: a reaction's
  /// author, or the agents composing recorded in its references.
  static List<String> _namesOf(Message say) {
    final reaction = say.reaction;
    if (reaction == null) return mentionedAgents(say.references);
    return [?nameOf(reaction.author)];
  }

  static bool _notSaid(Message message) => isCommand(message.plainText);
}

/// A `!` command or a callback `/skill` rather than something said: neither
/// addresses anyone, and neither steers a running turn.
bool isCommand(String text) =>
    shellBypassCommand(text) != null || wiredSkillFromText(text) != null;
