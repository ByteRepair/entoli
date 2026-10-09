import "../../domain/artifact.dart";
import "../../domain/ask.dart";
import "../../domain/file_tools.dart";
import "../../domain/models.dart";
import "../../domain/plan.dart";
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
  /// Keyed on the part rather than the message: a reply is rebuilt part-list
  /// and all on every flush, but the parts themselves keep their identity, so
  /// only the one still being written has to be turned into lines again — and
  /// a reply with a tool call in it is several parts.
  var _cache = Map<MessagePart, List<VoiceLine>>.identity();
  List<Message>? _of;
  var _lines = const <VoiceLine>[];

  /// The one part identity cannot answer for: the part being written is a new
  /// object on every flush, so it is the whole reply stripped again each time.
  final _growing = SpeakableText();

  List<VoiceLine> of(List<Message> messages) {
    // The whole list, not only its pieces: the page rebuilds on every coalesced
    // delta, and flattening a conversation to draw five lines of it is the cost
    // this class exists to avoid.
    if (identical(_of, messages)) return _lines;
    final kept = Map<MessagePart, List<VoiceLine>>.identity();
    final out = <VoiceLine>[];
    final last = messages.isEmpty ? null : messages.last;
    for (final message in messages) {
      final growing = identical(message, last) && message.parts.isNotEmpty
          ? message.parts.last
          : null;
      for (final part in message.parts) {
        final lines = identical(part, growing)
            ? linesOf(message.role, part, _growing)
            : _cache[part] ?? linesOf(message.role, part);
        kept[part] = lines;
        out.addAll(lines);
      }
    }
    // Replaced rather than added to, so a rewound or re-threaded conversation
    // does not leave the parts it dropped in here for the session.
    _cache = kept;
    _of = messages;
    return _lines = out;
  }
}

/// What one part reads as. What was said and what was replied, in the words
/// they were said in, and a line for each thing the agent did in between.
///
/// The reply is put through [speakable] rather than shown raw, so the lines on
/// screen are the ones being read out — a heading's hashes and a fenced command
/// belong to the chat page, which is still there.
List<VoiceLine> linesOf(MessageRole role, MessagePart part, [SpeakableText? growing]) {
  if (role == MessageRole.user) {
    if (part is! TextPart) return const [];
    final said = part.text.trim();
    return said.isEmpty ? const [] : [VoiceLine(VoiceLineKind.said, said)];
  }
  if (role != MessageRole.assistant) return const [];

  switch (part) {
    case TextPart(:final text):
      final spoken = growing?.of(text) ?? speakable(text);
      return spoken.isEmpty ? const [] : [VoiceLine(VoiceLineKind.replied, spoken)];
    case ToolCallPart(:final toolCall):
      final doing = _doing(toolCall.name);
      return doing == null ? const [] : [VoiceLine(VoiceLineKind.activity, doing)];
    case ErrorPart(:final message):
      return [VoiceLine(VoiceLineKind.activity, message)];
    // Typed rather than said — a `!` message from before voice mode was
    // opened. It reads as what the agent's own command reads as.
    case ShellRunPart():
      return const [VoiceLine(VoiceLineKind.activity, _ranACommand)];
    case ReasoningPart():
    case ToolResultPart():
    case FilePart():
    case ArtifactPart():
    case SkillInstallPart():
    case ApprovalPart():
    case InstructionsPart():
      return const [];
  }
}

/// What a tool call reads as. The four spelled out are the agent's own, whose
/// names live in `data/builtin` and are not `ui`'s to import; the rest are in
/// `domain/`, which `file_tools.dart` says in so many words is where they are
/// *because* the UI draws labels from them.
/// Read out for a command whoever ran it — the model through `bash`, or the
/// user through `!`.
const _ranACommand = "Ran a command";

String? _doing(String tool) => switch (tool) {
      "bash" => _ranACommand,
      "websearch" => "Searched the web",
      "webfetch" => "Read a page",
      "task" => "Ran a sub-agent",
      readToolName => "Read a file",
      writeToolName => "Wrote a file",
      editToolName => "Edited a file",
      artifactToolName => "Made an artifact",
      presentPlanToolName => "Presented the plan",
      planAddToolName => null,
      planNextToolName => null,
      planDoneToolName => null,
      // The panel below is where a question belongs, not a line above it.
      askToolName => null,
      _ => "Used $tool",
    };
