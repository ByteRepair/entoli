// Animations a live Bot Avatar plays over its mood for a while: a reaction
// rather than a state, so it ends by itself and the mood underneath comes
// back. Pure: what it shows is a function of how far in it is.
import "dart:math" as math;

import "pose.dart";

/// A mood held for [duration] over whatever the avatar was doing, with an
/// optional full turn about its vertical axis part way in.
class BotAnimation {
  const BotAnimation._({
    required this.mood,
    required this.duration,
    this.spin = false,
  });

  /// What a tap plays: pleased for five seconds, turning right round once
  /// in [_spinChance] of them.
  factory BotAnimation.tapped(math.Random random) => BotAnimation._(
    mood: BotMood.happy,
    duration: const Duration(seconds: 5),
    spin: random.nextDouble() < _spinChance,
  );

  static const _spinChance = 0.15;

  /// The spin starts once the first hop is under way and takes a little
  /// under a second.
  static const _spinStart = Duration(milliseconds: 350);
  static const _spinLength = Duration(milliseconds: 900);

  final BotMood mood;
  final Duration duration;
  final bool spin;

  /// The extra yaw [elapsed] in, radians: one eased full turn, then none,
  /// so the end of the spin is the pose it started from.
  double yawAt(Duration elapsed) {
    if (!spin) return 0;
    final u =
        (elapsed - _spinStart).inMicroseconds / _spinLength.inMicroseconds;
    if (u <= 0 || u >= 1) return 0;
    return 2 * math.pi * smoothstep(u);
  }
}
