import "dart:math" as math;
import "dart:ui" as ui;

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

import "../../theme.dart";
import "../voice_controller.dart";

/// What voice mode is mostly made of: an orb of light under the word for what
/// it is doing. It breathes while it listens and swells with the microphone on
/// top of that, sheds rings as it goes, orbits while a turn runs, beats as the
/// reply is read out, and sits dim and still while the microphone is shut.
///
/// Tapping it is the one way to stop whatever it is doing — the reply if it is
/// talking, which is the fallback wherever the platform's echo cancellation is
/// not good enough to hear the user over it, and otherwise the microphone.
class VoiceBloom extends StatefulWidget {
  const VoiceBloom({super.key, required this.state, this.onTap});

  final VoiceViewState state;
  final VoidCallback? onTap;

  /// The most the orb and the widest ring it sheds take together. Given less
  /// than this — a short screen, or one with a question panel under it — the
  /// whole thing is drawn smaller rather than clipped.
  static const size = 280.0;

  @override
  State<VoiceBloom> createState() => _VoiceBloomState();
}

class _VoiceBloomState extends State<VoiceBloom> with TickerProviderStateMixin {
  /// The rings and the orbit alike: they are never on screen together, so what
  /// a status changes is its period.
  late final AnimationController _cycle = AnimationController(vsync: this);

  /// The orb's own slow breath, which is a different period from the rings and
  /// so cannot be read off [_cycle] without jumping where that one wraps.
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  /// What the orb currently follows, held rather than rebuilt in `build`: a
  /// fresh merge every frame makes `AnimatedBuilder` detach and reattach its
  /// listeners, and this rebuilds whenever the page does.
  late Listenable _driven = _driver();

  /// The gradients the orb is made of. A shader is a native allocation, and
  /// the colour it is made from only changes when the status does.
  BloomLight? _light;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didUpdateWidget(VoiceBloom old) {
    super.didUpdateWidget(old);
    if (widget.state.status == old.state.status &&
        widget.state.paused == old.state.paused &&
        widget.state.level == old.state.level) {
      return;
    }
    _run();
    _driven = _driver();
  }

  /// A `ValueListenable`, not an `Animation`: what a session hands over is a
  /// notifier, and casting it was a crash waiting for the first device.
  ValueListenable<double> get _level =>
      widget.state.level ?? const AlwaysStoppedAnimation(0.0);

  /// Only what this mode actually reads. The microphone stays open while the
  /// reply is spoken, so following it there would repaint the orb thirty times
  /// a second for a level nothing draws.
  Listenable _driver() => switch (_mode) {
        BloomMode.listening => Listenable.merge([_cycle, _breath, _level]),
        BloomMode.speaking || BloomMode.thinking => _cycle,
        BloomMode.still => const AlwaysStoppedAnimation(0.0),
      };

  /// Only what this mode has moving. Left running, a hushed microphone or a
  /// failed session is repainted sixty times a second to draw the same frame,
  /// with a wake lock held.
  void _run() {
    final period = _period;
    if (period == null) {
      _cycle.stop();
    } else if (!_cycle.isAnimating || _cycle.duration != period) {
      _cycle.duration = period;
      _cycle.repeat();
    }
    // Only listening breathes: a running turn has the arcs to say so, and a
    // reply beats with what is leaving it.
    final breathing = _mode == BloomMode.listening;
    if (breathing == _breath.isAnimating) return;
    breathing ? _breath.repeat(reverse: true) : _breath.stop();
  }

  /// How long one turn of what this mode is doing takes: a ring leaving the
  /// orb, or the arcs going round once.
  Duration? get _period => switch (_mode) {
        BloomMode.listening => const Duration(milliseconds: 2900),
        BloomMode.speaking => const Duration(milliseconds: 1250),
        BloomMode.thinking => const Duration(milliseconds: 1500),
        BloomMode.still => null,
      };

  /// The microphone is shut and nothing is being said, which is the one look
  /// that is about the state rather than the status.
  bool get _hushed =>
      widget.state.paused && widget.state.status != VoiceStatus.speaking;

  BloomMode get _mode => switch (widget.state.status) {
        _ when _hushed => BloomMode.still,
        VoiceStatus.listening => BloomMode.listening,
        VoiceStatus.speaking => BloomMode.speaking,
        VoiceStatus.thinking || VoiceStatus.starting => BloomMode.thinking,
        VoiceStatus.off || VoiceStatus.failed => BloomMode.still,
      };

  @override
  void dispose() {
    _breath.dispose();
    _cycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = _mode;
    // Paused reads as off rather than as a state of listening, since that is
    // what it is: the device has stopped recording.
    final colour = switch (widget.state.status) {
      VoiceStatus.failed => theme.colorScheme.error,
      _ when _hushed => theme.colorScheme.onSurfaceVariant,
      VoiceStatus.speaking => spokenColour(theme.brightness),
      _ => heardColour(theme.brightness),
    };
    // A still orb is one nothing is happening in, so it is lit lower rather
    // than only being smaller.
    final lit = mode == BloomMode.still ? colour.withValues(alpha: 0.5) : colour;
    final hot = _hot(lit, theme.brightness);
    final light = _light = _light?.of(lit, hot) ?? BloomLight(lit, hot);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The word, because motion cannot say `starting` or `failed`, and a
        // glyph in the orb is a thing to decode.
        ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(shape: BoxShape.circle, color: colour),
              ),
              const SizedBox(width: 8),
              Text(
                _word(widget.state.status).toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 2.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Flexible(
          child: Semantics(
            label: _describe(widget.state.status),
            button: widget.onTap != null,
            child: GestureDetector(
              onTap: widget.onTap,
              child: RepaintBoundary(
                child: LayoutBuilder(
                  builder: (context, room) {
                    final side =
                        math.min(room.biggest.shortestSide, VoiceBloom.size);
                    return AnimatedBuilder(
                      animation: _driven,
                      builder: (context, _) => CustomPaint(
                        size: Size.square(side),
                        painter: BloomPainter(
                          mode: mode,
                          light: light,
                          side: side,
                          phase: _cycle.value,
                          breath: _breath.value,
                          // Nothing follows it in the other modes, so a level
                          // arriving from a microphone that is closing changes
                          // nothing on screen.
                          level: mode == BloomMode.listening ? _level.value : 0,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _word(VoiceStatus status) => switch (status) {
        _ when _hushed => "Paused",
        VoiceStatus.off => "Off",
        VoiceStatus.starting => "Starting",
        VoiceStatus.listening => "Listening",
        VoiceStatus.thinking => "Thinking",
        VoiceStatus.speaking => "Speaking",
        VoiceStatus.failed => "Failed",
      };

  /// The word again, with what tapping would do to it — which is the one thing
  /// on this screen a reader cannot see.
  String _describe(VoiceStatus status) {
    final hint = switch (status) {
      _ when _hushed => "Tap to listen.",
      VoiceStatus.speaking => "Tap to stop.",
      VoiceStatus.listening || VoiceStatus.thinking => "Tap to pause.",
      _ => null,
    };
    return hint == null ? _word(status) : "${_word(status)}. $hint";
  }
}

/// How the orb is drawn, which is not the same question as the status: a
/// hushed microphone, a failed session and voice mode off all look alike, and
/// a turn that is starting looks like one that is running.
enum BloomMode { still, listening, thinking, speaking }

/// The orb, the rings leaving it and the arcs going round it.
class BloomPainter extends CustomPainter {
  const BloomPainter({
    required this.mode,
    required this.light,
    required this.side,
    required this.phase,
    required this.breath,
    required this.level,
  });

  final BloomMode mode;
  final BloomLight light;

  /// The square this is drawn in, which is [reach] orbs across.
  final double side;

  /// Where in its cycle whatever is moving has got to, 0 to 1.
  final double phase;

  /// The orb's own breath, 0 to 1 and back.
  final double breath;

  /// How loud the microphone is, and zero wherever that is not being followed.
  final double level;

  /// How far a ring gets from the orb before it is gone, as a multiple of it,
  /// and so how much of the box is room for the rings.
  static const reach = 2.35;

  /// The orb at rest.
  double get core => side / (2 * reach);

  static const _rings = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final orb = core *
        switch (mode) {
          // The breath is what keeps a quiet room alive; the voice rides on
          // top of it.
          BloomMode.listening => (0.86 + 0.28 * breath) * (1 + level * 0.22),
          BloomMode.speaking => 1.02 + 0.2 * _beat,
          BloomMode.thinking => 0.74,
          BloomMode.still => 0.66,
        };

    if (mode == BloomMode.listening || mode == BloomMode.speaking) {
      // A ring is worth more when a voice shed it than when the room did.
      final shed = mode == BloomMode.listening ? 0.55 + 0.45 * level : 1.0;
      for (var i = 0; i < _rings; i++) {
        _ring(canvas, centre, orb, (phase + i / _rings) % 1, shed);
      }
    }
    if (mode == BloomMode.thinking) {
      final turned = phase * 2 * math.pi;
      _arc(canvas, centre, orb * 2.0, turned, math.pi * 0.5, 0.9);
      _arc(canvas, centre, orb * 2.36, -turned * 0.62, math.pi * 0.28, 0.45);
    }

    _lit(canvas, centre, orb * (1.3 + level * 0.4), light.halo);
    _lit(canvas, centre, orb, light.core);
  }

  /// How far into shedding the current ring the reply has got. Three leave per
  /// cycle, so a reply beats about twice a second — which is what makes the
  /// orb read as talking rather than as sitting there brightly.
  double get _beat => math.pow(1 - (phase * _rings) % 1, 2.5).toDouble();

  /// Drawn as a unit circle under a scale, so the gradient is one that was
  /// made once rather than one made to fit this frame's radius.
  void _lit(Canvas canvas, Offset centre, double radius, ui.Shader shader) {
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(radius);
    canvas.drawCircle(Offset.zero, 1, Paint()..shader = shader);
    canvas.restore();
  }

  /// A ring slows as it widens and thins as it goes, which is what makes it
  /// read as something leaving rather than a circle being resized. It travels
  /// from the orb as it is now to the edge of the box, so a swollen orb does
  /// not push its own rings off the screen.
  void _ring(Canvas canvas, Offset centre, double orb, double at, double shed) {
    final out = Curves.easeOut.transform(at);
    canvas.drawCircle(
      centre,
      orb + (core * reach - orb) * out,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 - 1.8 * out
        ..color = light.glow
            .withValues(alpha: 0.6 * math.pow(1 - out, 1.3) * shed),
    );
  }

  void _arc(Canvas canvas, Offset centre, double radius, double from,
      double sweep, double alpha) {
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      from,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.6
        ..color = light.glow.withValues(alpha: alpha),
    );
  }

  /// The box is mostly the room the rings need, so only the orb and its glow
  /// answer a tap. Stopping a reply from a hand's width away is a surprise.
  @override
  bool hitTest(Offset position) =>
      (position - Offset(side / 2, side / 2)).distance <= core * 1.7;

  @override
  bool shouldRepaint(BloomPainter old) =>
      old.mode != mode ||
      old.side != side ||
      old.phase != phase ||
      old.breath != breath ||
      old.level != level ||
      old.light != light;
}

/// The hot middle of the orb, and what its rings are drawn in. Away from the
/// page rather than always lighter: a centre lightened on a white surface is a
/// hole in the orb rather than a light in it.
Color _hot(Color colour, Brightness brightness) {
  final hsl = HSLColor.fromColor(colour);
  final by = brightness == Brightness.dark ? 0.2 : -0.14;
  return hsl.withLightness((hsl.lightness + by).clamp(0.0, 1.0)).toColor();
}

/// The two gradients an orb is made of, over a unit circle so that one set
/// serves every radius it is drawn at.
class BloomLight {
  BloomLight(this.colour, this.glow)
      : core = RadialGradient(
          // Lit from a little above the middle, so it reads as a body of light
          // rather than as a disc.
          center: const Alignment(0, -0.16),
          colors: [
            glow.withValues(alpha: colour.a * 0.98),
            colour.withValues(alpha: colour.a * 0.92),
            colour.withValues(alpha: 0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(_unit),
        halo = RadialGradient(
          colors: [
            colour.withValues(alpha: colour.a * 0.26),
            colour.withValues(alpha: 0),
          ],
          stops: const [0.3, 1],
        ).createShader(_unit);

  final Color colour;
  final Color glow;
  final ui.Shader core;
  final ui.Shader halo;

  /// This set if it is the one asked for, and a new one if it is not.
  BloomLight of(Color wanted, Color hot) =>
      wanted == colour && hot == glow ? this : BloomLight(wanted, hot);

  static final _unit = Rect.fromCircle(center: Offset.zero, radius: 1);
}
