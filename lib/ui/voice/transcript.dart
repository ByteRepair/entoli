import "../../domain/artifact.dart";
import "../../domain/ask.dart";
import "../../domain/file_tools.dart";
import "../../domain/models.dart";
import "../../domain/speech_text.dart";

/// Who a transcript line belongs to. Three rather than the issue's two: a turn
/// can spend half a minute inside a sub-agent, and a screen that says nothing
/// while it does reads as a broken app rather than a working one.
enum VoiceLineKind { said, replied, activity }

class VoiceLine {
  const VoiceLine(this.kind, this.text);

  final VoiceLineKind kind;
  final String text;
}

/// The conversation as something to read five lines of, message by message and
/// **kept between rebuilds**. A turn flushes its state around sixty times a
/// second, and turning every message ever said back into speech text each time
/// costs more the longer the conversation is, to redraw five lines.
///
/// `identical` on the parts is an exact check rather than a guess: a message is
/// rebuilt whole with a fresh part list whenever anything in it changes, so
/// the same list is the same lines.
class Transcript {
  final _cache = <String, ({List<MessagePart> parts, List<VoiceLine> lines})>{};

  List<VoiceLine> of(List<Message> messages) {
    final kept = <String, ({List<MessagePart> parts, List<VoiceLine> lines})>{};
    final out = <VoiceLine>[];
    for (final message in messages) {
      final was = _cache[message.id];
      final lines = was != null && identical(was.parts, message.parts)
          ? was.lines
          : linesOf(message);
      kept[message.id] = (parts: message.parts, lines: lines);
      out.addAll(lines);
    }
    // Rebuilt rather than added to, so a rewound or re-threaded conversation
    // does not leave the messages it dropped in here for the session.
    _cache
      ..clear()
      ..addAll(kept);
    return out;
  }
}

/// What one message reads as. What was said and what was replied, in the words
/// they were said in, and a line for each thing the agent did in between.
///
/// The reply is put through [speakable] rather than shown raw, so the lines on
/// screen are the ones being read out — a heading's hashes and a fenced command
/// belong to the chat page, which is still there.
List<VoiceLine> linesOf(Message message) {
  if (message.role == MessageRole.user) {
    final text = message.plainText.trim();
    return text.isEmpty ? const [] : [VoiceLine(VoiceLineKind.said, text)];
  }
  if (message.role != MessageRole.assistant) return const [];

  final lines = <VoiceLine>[];
  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        final spoken = speakable(text).trim();
        if (spoken.isNotEmpty) lines.add(VoiceLine(VoiceLineKind.replied, spoken));
      case ToolCallPart(:final toolCall):
        final doing = _doing(toolCall.name);
        if (doing != null) lines.add(VoiceLine(VoiceLineKind.activity, doing));
      case ErrorPart(:final message):
        lines.add(VoiceLine(VoiceLineKind.activity, message));
      case ReasoningPart():
      case ToolResultPart():
      case FilePart():
      case ArtifactPart():
        break;
    }
  }
  return lines;
}

/// What a tool call reads as. The four spelled out are the agent's own, whose
/// names live in `data/builtin` and are not `ui`'s to import; the rest are in
/// `domain/`, which `file_tools.dart` says in so many words is where they are
/// *because* the UI draws labels from them.
String? _doing(String tool) => switch (tool) {
      "bash" => "Ran a command",
      "websearch" => "Searched the web",
      "webfetch" => "Read a page",
      "task" => "Ran a sub-agent",
      readToolName => "Read a file",
      writeToolName => "Wrote a file",
      editToolName => "Edited a file",
      artifactToolName => "Made an artifact",
      // The panel below is where a question belongs, not a line above it.
      askToolName => null,
      _ => "Used $tool",
    };
