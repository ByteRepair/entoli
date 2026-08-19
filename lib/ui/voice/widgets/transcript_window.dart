import "dart:ui" as ui;

import "package:flutter/material.dart";

import "../../widgets/scrolling.dart";
import "../transcript.dart";

/// Five lines of the conversation, and it **scrolls**: a window onto every line
/// said rather than five that roll past and are gone. See "The screen" in
/// CLAUDE.md for what follows from it being a viewport rather than a buffer.
class TranscriptWindow extends StatefulWidget {
  const TranscriptWindow({super.key, required this.lines});

  final List<VoiceLine> lines;

  /// How many fit before it scrolls.
  static const visibleLines = 5;

  /// What one line takes, over the size `bodyLarge` renders at so the text
  /// still fits once scaled.
  static const lineHeight = 24.0;

  @override
  State<TranscriptWindow> createState() => _TranscriptWindowState();
}

class _TranscriptWindowState extends State<TranscriptWindow> {
  final _scroll = ScrollController();

  /// How far off the end still counts as reading the latest. One line: this is
  /// five lines tall, so the chat page's 200 pixels would be the whole thing.
  static const _slack = TranscriptWindow.lineHeight;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TranscriptWindow old) {
    super.didUpdateWidget(old);
    if (widget.lines.length != old.lines.length) _follow();
  }

  void _follow() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final position = _scroll.position;
        if (position.nearBottom(_slack)) _scroll.jumpTo(position.maxScrollExtent);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: scaler.scale(TranscriptWindow.lineHeight) * TranscriptWindow.visibleLines,
      child: ShaderMask(
        shaderCallback: _fadeShader,
        blendMode: BlendMode.dstIn,
        child: ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.zero,
          itemCount: widget.lines.length,
          itemBuilder: (context, i) {
            final line = widget.lines[i];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line.text,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: switch (line.kind) {
                    // What the user said sits back; what was said to them is the
                    // page. The issue asks for grey and white, taken through the
                    // scheme so light mode works too.
                    VoiceLineKind.said => theme.colorScheme.onSurfaceVariant,
                    VoiceLineKind.replied => theme.colorScheme.onSurface,
                    VoiceLineKind.activity => theme.colorScheme.outline,
                  },
                  fontStyle: line.kind == VoiceLineKind.activity
                      ? FontStyle.italic
                      : null,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The top of the window fading into the orb above it, so the line being
  /// read is the one at the bottom. A mask rather than an opacity per line,
  /// because this is a viewport: what should be faint is whatever is at the
  /// top of the *view*, and a line dimmed by its place in the list stays
  /// dimmed once it has been scrolled back to.
  static const _fade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.transparent, Colors.black],
    stops: [0, 0.42],
  );

  /// Kept between paints, and a tear-off rather than a closure: `ShaderMask`
  /// asks on every paint, a gradient is a native allocation, and a callback
  /// that is a new object each build repaints the list for nothing.
  static Rect? _madeFor;
  static ui.Shader? _made;

  static ui.Shader _fadeShader(Rect bounds) {
    if (bounds != _madeFor) {
      _madeFor = bounds;
      _made = _fade.createShader(bounds);
    }
    return _made!;
  }
}
