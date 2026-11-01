import "models.dart";
import "shell_job.dart" show firstLine;

/// What the user can react to a message with — any message, their own
/// included. A reaction is something said: it goes on the log as a user
/// message holding a [ReactionPart], and the room routes it to whoever wrote
/// the message, as it would a message mentioning them.
/// See "Reactions" in `lib/domain/AGENTS.md`.
enum Reaction {
  thumbsUp("👍", "thumbs up"),
  thumbsDown("👎", "thumbs down"),
  fire("🔥", "fire"),
  angry("😠", "anger"),
  sad("😢", "sadness"),
  thinking("🤔", "thinking");

  const Reaction(this.emoji, this.name);

  /// What the log keeps and the page draws.
  final String emoji;

  /// What the model is told beside the emoji: a small model reading 😠 alone
  /// is guessing.
  final String name;

  /// The reaction [emoji] is, or null for one this build does not offer — a
  /// log a newer build wrote.
  static Reaction? of(String emoji) =>
      values.where((r) => r.emoji == emoji).firstOrNull;
}

/// The user's [reaction] to [message], as the message that says it. It
/// carries [message]'s author, which only a member's reply has; whether that
/// routes to them is the room's to decide when it dispatches, the way it is
/// for a mention.
Message reactionTo(
  Message message,
  Reaction reaction, {
  required String id,
  required DateTime at,
}) => Message(
  id: id,
  role: MessageRole.user,
  createdAt: at,
  parts: [
    MessagePart.reaction(
      messageId: message.id,
      emoji: reaction.emoji,
      author: message.author,
      // Enough for the model to know which message it was: the message is
      // on the thread above, but a projection may be handed this alone.
      excerpt: firstLine(message.plainText, max: 200),
    ),
  ],
);

extension Reactions on Message {
  /// The reaction this message is, or null where it is anything else.
  ReactionPart? get reaction => parts.whereType<ReactionPart>().firstOrNull;
}

/// The reactions each message on [messages] has had, by its id, each emoji
/// once in the order first made — what its action row shows, and what its
/// picker shows chosen. A retracted one is off it. The reactions
/// themselves are not drawn: each is said, and shown on what it answers.
Map<String, List<String>> reactionsOn(List<Message> messages) {
  final on = <String, List<String>>{};
  for (final message in messages) {
    final reaction = message.reaction;
    if (reaction == null || message.retraction != null) continue;
    final emojis = on.putIfAbsent(reaction.messageId, () => []);
    if (!emojis.contains(reaction.emoji)) emojis.add(reaction.emoji);
  }
  return on;
}
