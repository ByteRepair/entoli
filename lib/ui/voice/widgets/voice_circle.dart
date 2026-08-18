import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

import "../voice_controller.dart";

/// The circle voice mode is mostly made of: it grows with the microphone while
/// it listens, breathes while a turn runs, and holds still while the reply is
/// read out. Tapping it is the one way to stop whatever it is doing — the reply
/// if it is talking, which is the fallback wherever the platform's echo
/// cancellation is not good enough to hear the user over it, and otherwise the
/// microphone.
class VoiceCircle extends StatefulWidget {
  const VoiceCircle({super.key, required this.state, this.onTap});

  final VoiceViewState state;
  final VoidCallback? onTap;

  @override
  State<VoiceCircle> createState() => _VoiceCircleState();
}

class _VoiceCircleState extends State<VoiceCircle> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// What the circle currently follows, held rather than rebuilt in `build`: a
  /// fresh merge every frame makes `AnimatedBuilder` detach and reattach its
  /// listeners, and this rebuilds whenever the page does.
  late Listenable _driven = _driver();

  @override
  void initState() {
    super.initState();
    _breathe();
  }

  @override
  void didUpdateWidget(VoiceCircle old) {
    super.didUpdateWidget(old);
    if (widget.state.status != old.state.status) _breathe();
    if (widget.state.level != old.state.level ||
        widget.state.status != old.state.status ||
        widget.state.paused != old.state.paused) {
      _driven = _driver();
    }
  }

  /// A `ValueListenable`, not an `Animation`: what a session hands over is a
  /// notifier, and casting it was a crash waiting for the first device.
  ValueListenable<double> get _level =>
      widget.state.level ?? const AlwaysStoppedAnimation(0.0);

  /// Only what this status actually reads. The microphone stays open while the
  /// reply is spoken, so following it there would repaint the circle thirty
  /// times a second to draw the same frame.
  Listenable _driver() => switch (widget.state.status) {
        VoiceStatus.listening when !widget.state.paused => _level,
        VoiceStatus.thinking || VoiceStatus.starting => _breath,
        _ => const AlwaysStoppedAnimation(0.0),
      };

  /// Only while there is nothing else to follow. Left running, the circle is
  /// laid out and repainted sixty times a second to draw the same frame, for a
  /// whole session with the microphone open and a wake lock held.
  void _breathe() {
    final wanted = widget.state.status == VoiceStatus.thinking ||
        widget.state.status == VoiceStatus.starting;
    if (wanted == _breath.isAnimating) return;
    wanted ? _breath.repeat(reverse: true) : _breath.stop();
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.state.status;
    // Paused reads as off rather than as a state of listening, since that is
    // what it is: the device has stopped recording.
    final hushed = _hushed;
    final colour = switch (status) {
      VoiceStatus.failed => theme.colorScheme.error,
      _ when hushed => theme.colorScheme.onSurfaceVariant,
      VoiceStatus.speaking => theme.colorScheme.tertiary,
      _ => theme.colorScheme.primary,
    };
    return Semantics(
      label: _describe(status),
      button: widget.onTap != null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _driven,
          // The glyph follows neither animation, so it is built once and
          // handed in rather than rebuilt per frame.
          child: Icon(_icon(status), size: _size * 0.34, color: colour),
          builder: (context, child) {
            // Listening follows the voice; thinking has nothing to follow, so
            // it breathes instead of sitting dead still.
            final grown = switch (status) {
              _ when hushed => 0.0,
              VoiceStatus.listening => _level.value * 0.35,
              VoiceStatus.thinking || VoiceStatus.starting => _breath.value * 0.12,
              VoiceStatus.speaking => 0.08,
              _ => 0.0,
            };
            return SizedBox(
              width: _size * 1.4,
              height: _size * 1.4,
              child: Center(
                child: Container(
                  width: _size * (1 + grown),
                  height: _size * (1 + grown),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colour.withValues(alpha: 0.18),
                    border: Border.all(color: colour, width: 2),
                  ),
                  child: child,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static const _size = 160.0;

  /// The microphone is shut and nothing is being said, which is the one look
  /// that is about the state rather than the status.
  bool get _hushed =>
      widget.state.paused && widget.state.status != VoiceStatus.speaking;

  IconData _icon(VoiceStatus status) => switch (status) {
        _ when _hushed => Icons.mic_off_outlined,
        VoiceStatus.failed => Icons.error_outline,
        VoiceStatus.speaking => Icons.volume_up_outlined,
        VoiceStatus.thinking => Icons.more_horiz,
        VoiceStatus.starting => Icons.hourglass_empty,
        _ => Icons.mic_none,
      };

  String _describe(VoiceStatus status) => switch (status) {
        _ when _hushed => "Paused. Tap to listen.",
        VoiceStatus.off => "Voice mode off",
        VoiceStatus.starting => "Starting voice mode",
        VoiceStatus.listening => "Listening. Tap to pause.",
        VoiceStatus.thinking => "Thinking",
        VoiceStatus.speaking => "Speaking. Tap to stop.",
        VoiceStatus.failed => "Voice mode failed",
      };
}
