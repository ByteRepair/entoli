import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart";
import "activity.dart";
import "card.dart";
import "format.dart";
import "label.dart";

/// A thinking block, on a line of its own above the reply. While the block
/// is being written its tail streams under the label, so the thinking is read
/// as it happens rather than only once it is over, and the block is what the
/// turn is busy with.
class ThinkingActivity extends LabelledActivity {
  const ThinkingActivity();

  @override
  bool important(Run run) => run.going;

  @override
  RunView view(WidgetRef ref, Run run) {
    final part = run.part! as ReasoningPart;
    final ms = part.durationMs;
    return RunView(
      icon: Icons.psychology_outlined,
      label: run.going
          ? "Thinking…"
          // Neither streamed nor timed: an older conversation, or an aborted
          // turn.
          : ms == null
          ? "View thinking"
          : "Thought for ${formatThinkingTime(ms)}",
      drawer: (_) => RunDrawer(
        title: run.going ? "Thinking…" : "Thinking",
        sections: [(label: null, body: part.text, isError: false)],
      ),
    );
  }

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

  @override
  Widget build(Run run) {
    final label = super.build(run);
    final part = run.part! as ReasoningPart;
    if (!run.going || part.text.trim().isEmpty) return label;
    return Builder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          label,
          _ThoughtTail(text: part.text, onTap: () => open(context, run)),
        ],
      ),
    );
  }
}

/// The last few lines of a thought being written, faded at the top so it
/// reads as the end of something longer. The drawer has the whole of it.
class _ThoughtTail extends StatelessWidget {
  const _ThoughtTail({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  static const _lines = 4;

  /// What is laid out per delta. Only the tail is ever shown, and laying out
  /// a long thought whole every frame to show its last lines is the cost.
  static const _tailChars = 800;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );
    final lineHeight = (style?.fontSize ?? 12) * (style?.height ?? 1.4);
    final tail = text.length > _tailChars
        ? text.substring(text.length - _tailChars)
        : text;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          labelPadX + labelIcon + labelGap,
          0,
          labelPadX,
          6,
        ),
        child: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black],
            stops: [0, 0.45],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: SizedBox(
            height: lineHeight * _lines,
            width: double.infinity,
            // Reversed so the newest line is the one held in view.
            child: SingleChildScrollView(
              reverse: true,
              physics: const NeverScrollableScrollPhysics(),
              child: Text(tail.trim(), style: style),
            ),
          ),
        ),
      ),
    );
  }
}
