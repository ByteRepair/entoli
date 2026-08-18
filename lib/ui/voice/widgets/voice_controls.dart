import "package:flutter/material.dart";

import "../voice_controller.dart";

/// The three things there are to do to a voice session: shut the microphone,
/// stop the reply being read out, and go back to typing.
///
/// One button each, because they are three different promises. All three were
/// the orb at first — which one a tap meant depended on the status, so the same
/// gesture stopped a reply, shut a microphone or did nothing at all, and
/// nothing on screen said any of it could be tapped.
class VoiceControls extends StatelessWidget {
  const VoiceControls({
    super.key,
    required this.state,
    required this.onMute,
    required this.onStop,
    required this.onDone,
  });

  final VoiceViewState state;

  /// Shut the microphone, or open it again.
  final VoidCallback onMute;

  /// Stop the reply. Dead unless there is one being read out.
  final VoidCallback onStop;

  /// Leave voice mode, which is the chat as it already was.
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final speaking = state.status == VoiceStatus.speaking;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 28,
      children: [
        _Key(
          icon: state.paused ? Icons.mic_off_outlined : Icons.mic_none,
          label: state.paused ? "Listen" : "Mute",
          tooltip: state.paused ? "Open the microphone" : "Shut the microphone",
          held: state.paused,
          onPressed: state.isOn ? onMute : null,
        ),
        _Key(
          icon: Icons.stop_rounded,
          label: "Stop",
          tooltip: "Stop the reply",
          // The reply's own colour, so the one button that comes alive
          // mid-turn is lit in what is doing the talking.
          accent: speaking ? voiceColour(state, Theme.of(context)) : null,
          onPressed: speaking ? onStop : null,
        ),
        _Key(
          icon: Icons.keyboard_arrow_down_rounded,
          label: "Done",
          tooltip: "Back to typing",
          onPressed: onDone,
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.accent,
    this.held = false,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tooltip;

  /// What to draw this one in while it has something to say. Null is the
  /// ordinary look.
  final Color? accent;

  /// Whether this is the button that is currently engaged, which is the muted
  /// microphone and nothing else.
  final bool held;

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dead = onPressed == null;
    final colour = accent ?? scheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(icon),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(52),
            shape: const CircleBorder(),
            foregroundColor: held ? scheme.onSecondaryContainer : colour,
            backgroundColor:
                held ? scheme.secondaryContainer : scheme.surfaceContainerLow,
            disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.3),
            side: BorderSide(
              color: dead
                  ? scheme.outlineVariant.withValues(alpha: 0.5)
                  : accent?.withValues(alpha: 0.7) ?? scheme.outlineVariant,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: dead
                ? scheme.onSurface.withValues(alpha: 0.3)
                : scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
