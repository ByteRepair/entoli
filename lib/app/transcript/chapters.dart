import "../../domain/end_turn.dart" show drawnAsRow;
import "../../domain/models.dart";

/// One thing the user said, as a place in the conversation to go back to.
typedef Chapter = ({
  /// The message id of what was said, which is what the page scrolls to: a
  /// prompt's, or a steer's inside the reply it was read into.
  String id,

  /// The message whose row it is in: the prompt itself, or the reply a steer
  /// was read into.
  String row,

  /// Its first line, for the rail's tooltip, cut to [_previewLength].
  String preview,

  /// How many threads were written somewhere in this turn — at the prompt (an
  /// edit) or at a reply under it (a regenerate). One where nothing branched,
  /// and on a steer, which is not where a turn starts.
  int threads,
});

/// The chapters of the thread being read: every prompt, and every steer said
/// over a turn, oldest first. A turn is the prompt and what answered it, up
/// to the next prompt, so a branch at any message in it marks the prompt's
/// chapter.
List<Chapter> chaptersOf(Chat chat) {
  final chapters = <Chapter>[];
  int? prompt;
  for (final message in chat.messages) {
    // Only what is drawn has a place to go back to.
    if (!drawnAsRow(message)) continue;
    final threads = chat.threadsAt(message.id).length;
    if (message.role == MessageRole.user) {
      prompt = chapters.length;
      chapters.add((
        id: message.id,
        row: message.id,
        preview: _firstLine(message.plainText),
        threads: threads,
      ));
      continue;
    }
    final at = prompt;
    if (at != null && threads > chapters[at].threads) {
      final p = chapters[at];
      chapters[at] = (
        id: p.id,
        row: p.row,
        preview: p.preview,
        threads: threads,
      );
    }
    for (final part in message.parts) {
      if (part case SteerPart(message: final said)) {
        chapters.add((
          id: said.id,
          row: message.id,
          preview: _firstLine(said.plainText),
          threads: 1,
        ));
      }
    }
  }
  return chapters;
}

/// How much of a prompt the tooltip shows.
const _previewLength = 50;

String _firstLine(String text) {
  final trimmed = text.trim();
  final end = trimmed.indexOf("\n");
  final line = (end < 0 ? trimmed : trimmed.substring(0, end)).trim();
  if (line.isEmpty) return "(attachment)";
  if (line.length <= _previewLength) return line;
  return "${line.substring(0, _previewLength).trimRight()}...";
}
