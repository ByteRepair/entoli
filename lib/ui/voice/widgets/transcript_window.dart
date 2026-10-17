import "dart:ui" as ui;

import "package:flutter/material.dart";

import "../../widgets/scrolling.dart";
import "../transcript.dart";

/// Five lines of the conversation, and it **scrolls**: a window onto every line
/// said rather than five that roll past and are gone. See "The screen" in
/// AGENTS.md for what follows from it being a viewport rather than a buffer.
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
  late final ScrollController _scroll = ScrollController();
  late final ScrollFollow _follow = ScrollFollow(_scroll);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TranscriptWindow old) {
    super.didUpdateWidget(old);
    // Identity, not length: a reply growing in place wraps onto more rows.
    if (!identical(widget.lines, old.lines)) _keepUp();
  }

  /// A line the user has scrolled away from does not pull them back; see
  /// [ScrollFollow] for what detaches and what attaches again.
  void _keepUp() => _follow.jumpIfFollowing();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: scaler.scale(TranscriptWindow.lineHeight) * TranscriptWindow.visibleLines,
      child: ShaderMask(
        shaderCallback: _fadeShader,
        blendMode: BlendMode.dstIn,
        child: NotificationListener<ScrollNotification>(
          onNotification: _follow.onNotification,
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
                      // What the user said sits back; what was said to them is
                      // the page. The issue asks for grey and white, taken
                      // through the scheme so light mode works too.
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
