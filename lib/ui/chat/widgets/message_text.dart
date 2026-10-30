import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "code_block.dart";
import "reply_style.dart";

/// One line of a message bubble: raw text while the reply streams or when it is
/// an error, `MarkdownBody` once finished. Owns the markdown style sheet so the
/// parent's build does not rebuild it on every scroll frame.
///
/// Public because two homes render reply text now: the bubble's, and the
/// compaction summary beneath its divider — the same encoding, the same
/// rendering, whether the model wrote it as a reply or as a summary.
class MessageText extends StatefulWidget {
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

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  MarkdownStyleSheet? _styleSheet;

  /// Raw while the reply streams or when it is an error: there is no markdown
  /// to render yet, and an error is not the model's prose.
  bool get _rendered => !widget.isWaiting && !widget.isError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _styleSheet = replyStyleSheet(Theme.of(context));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_rendered) {
      final style = widget.isError
          ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)
          : theme.textTheme.bodyMedium;
      // Rich only where there is a caret to put in it. Folding both into one
      // `Text.rich` reads tidier and costs the plain string: `Text.data` is
      // null for a span, so an error would stop being something `find.text`
      // and `.data` can reach, for no gain to anything on screen.
      if (!widget.caret) return Text(widget.text, style: style);
      return Text.rich(
        TextSpan(
          text: widget.text,
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
    // No `selectable`, and no container of its own: the fragments register
    // with the message's own container above, which is what makes a drag run
    // from the first paragraph to the last — `selectable` builds a
    // `SelectableText` per element, each a selection region to itself, which
    // is what made a selection stop at the paragraph it started in. The
    // bullets are chrome, like a code block's bar: on screen, but not part of
    // what a drag picks up, so what a selection copies reads as the list's
    // items rather than `•Item`.
    return MarkdownBody(
      data: widget.text,
      styleSheet: _styleSheet,
      builders: codeBlockBuilders,
      bulletBuilder: (parameters) => SelectionContainer.disabled(
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            "•",
            style:
                _styleSheet?.listBullet ??
                Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      ),
      onTapLink: (text, href, title) {
        if (href != null) widget.onTapLink?.call(href);
      },
    );
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
