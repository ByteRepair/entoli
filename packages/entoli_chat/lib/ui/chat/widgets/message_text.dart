import "package:flutter/material.dart";

import "markdown_text.dart";

/// One line of a message bubble: raw text while the reply streams or when it is
/// an error, `MarkdownText` once finished.
///
/// Public because two homes render reply text now: the bubble's, and the
/// compaction summary beneath its divider — the same encoding, the same
/// rendering, whether the model wrote it as a reply or as a summary.
class MessageText extends StatelessWidget {
  const MessageText({
    super.key,
    required this.text,
    required this.isError,
    required this.isWaiting,
    required this.caret,
    this.onTapLink,
  });

  final String text;
  final bool isError;
  final bool isWaiting;

  /// This is the text being written right now, so it ends in a caret.
  final bool caret;

  final ValueChanged<String>? onTapLink;

  /// Raw while the reply streams or when it is an error: there is no markdown
  /// to render yet, and an error is not the model's prose.
  bool get _rendered => !isWaiting && !isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_rendered) {
      final style = isError
          ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)
          : theme.textTheme.bodyMedium;
      // Rich only where there is a caret to put in it. Folding both into one
      // `Text.rich` reads tidier and costs the plain string: `Text.data` is
      // null for a span, so an error would stop being something `find.text`
      // and `.data` can reach, for no gain to anything on screen.
      if (!caret) return Text(text, style: style);
      return Text.rich(
        TextSpan(
          text: text,
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: StreamingCaret(
                color: theme.colorScheme.primary,
                // A bare rectangle inside the span rather than text in it, so
                // nothing else gives it a height.
                height: style?.fontSize ?? 14,
              ),
            ),
          ],
        ),
        style: style,
      );
    }
    return MarkdownText(text, onTapLink: onTapLink);
  }
}

/// Sits at the end of the text while it is still arriving. The bubble's
/// spinner answers for a reply that has said nothing yet; once there are
/// words, the thing worth pointing at is where the next one goes.
///
/// It fades rather than blinking on and off: a hard blink beside prose that is
/// itself growing reads as two things moving, and this has to be noticed
/// without being watched.
class StreamingCaret extends StatefulWidget {
  const StreamingCaret({super.key, required this.color, required this.height});

  final Color color;
  final double height;

  @override
  State<StreamingCaret> createState() => _StreamingCaretState();
}

class _StreamingCaretState extends State<StreamingCaret>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  /// Built once beside the controller rather than in `build`: a streaming reply
  /// rebuilds on every coalesced delta, and a fresh `Animation` each time makes
  /// the render object drop and re-add its listener for no change.
  ///
  /// It fades to 0.2 rather than to nothing, which also keeps the opacity layer
  /// a repaint boundary throughout — at zero it stops being one twice a cycle
  /// and takes the paragraph above it into the repaint.
  late final _opacity = _pulse.drive(Tween(begin: 1.0, end: 0.2));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: Container(
      // Beside the last word rather than against it.
      margin: const EdgeInsets.only(left: 2),
      width: 2,
      height: widget.height,
      color: widget.color,
    ),
  );
}
