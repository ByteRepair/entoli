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
      // What tells the model which message it was: the id is never shown to
      // it, and the message may be any of the thread's, or compacted away.
      excerpt: firstLine(message.plainText, max: 200),
    ),
  ],
);

extension Reactions on Message {
  /// The reaction this message is, or null where it is anything else.
  /// Only a user message can be one, so a reply's many parts are not walked.
  ReactionPart? get reaction => role == MessageRole.user
      ? parts.whereType<ReactionPart>().firstOrNull
      : null;
}

/// The reactions on [messages] not taken back, oldest first — to the message
/// [to] and with [emoji] where they are given. The one statement of what a
/// live reaction is: what the action row shows, what the picker shows
/// chosen, and what a retraction takes back.
Iterable<Message> liveReactions(
  List<Message> messages, {
  String? to,
  String? emoji,
}) => messages.where((m) {
  final reaction = m.reaction;
  return reaction != null &&
      m.retraction == null &&
      (to == null || reaction.messageId == to) &&
      (emoji == null || reaction.emoji == emoji);
});

/// The emoji each message on [messages] has live, by its id, each once in
/// the order first made. The reactions themselves are not drawn: each is
/// said, and shown on what it answers.
Map<String, List<String>> reactionsOn(List<Message> messages) {
  final on = <String, List<String>>{};
  for (final message in liveReactions(messages)) {
    final reaction = message.reaction!;
    final emojis = on.putIfAbsent(reaction.messageId, () => []);
    if (!emojis.contains(reaction.emoji)) emojis.add(reaction.emoji);
  }
  return on;
}
