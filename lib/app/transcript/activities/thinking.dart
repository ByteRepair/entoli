import "../../../core/formatting.dart" show plural;
import "../../../domain/models.dart";
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";

/// A thinking block, on a line of its own above the reply. While it is being
/// written its tail streams under the label, so the thinking is read as it
/// happens, and the block is what the turn is busy with.
final class ThinkingActivity extends Activity {
  const ThinkingActivity();

  /// What is laid out of a thought per delta: only the tail is shown.
  static const tailChars = 800;

  @override
  bool important(Run run) => run.going;

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final part = run.part! as ReasoningPart;
    final ms = part.durationMs;
    final text = part.text.trim();
    return LabelNode(
      this,
      run,
      glyph: TranscriptGlyph.thinking,
      text: run.going
          ? "Thinking…"
          // Neither streamed nor timed: an older conversation, or an aborted
          // turn.
          : ms == null
          ? "View thinking"
          : "Thought for ${formatThinkingTime(ms)}",
      tail: run.going && text.isNotEmpty
          ? (text.length > tailChars
                ? text.substring(text.length - tailChars)
                : text)
          : null,
    );
  }

  @override
  ActivityDetail detail(SettingReader reader, Run run) => ActivityDetail(
    title: run.going ? "Thinking…" : "Thinking",
    glyph: TranscriptGlyph.thinking,
    sections: [DetailSection(body: (run.part! as ReasoningPart).text)],
  );

  /// Found by where it sits, since a block has no id of its own.
  @override
  Run? follow(Run run, LiveMessage now) {
    final parts = now.message?.parts;
    final at = run.at;
    if (parts == null || at == null || at >= parts.length) return null;
    final part = parts[at];
    if (part is! ReasoningPart) return null;
    return Run(
      chatId: run.chatId,
      part: part,
      at: at,
      going: now.running && part.durationMs == null,
    );
  }
}

/// "12 seconds", "2 minutes 5 seconds" — what a label reads after "Thought for".
String formatThinkingTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  if (seconds < 1) return "a moment";
  if (seconds < 60) return plural(seconds, "second");
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  final head = plural(minutes, "minute");
  return rest == 0 ? head : "$head ${plural(rest, "second")}";
}
