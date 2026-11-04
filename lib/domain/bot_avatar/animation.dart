// Animations a live Bot Avatar plays over its mood for a while: a reaction
// rather than a state, so it ends by itself and the mood underneath comes
// back. Pure: what it shows is a function of how far in it is.
import "dart:math" as math;

import "pose.dart";

/// A mood held for [duration] over whatever the avatar was doing, with an
/// optional full turn about its vertical axis part way in.
class BotAnimation {
  const BotAnimation({
    required this.mood,
    required this.duration,
    this.spin = false,
  });

  /// What a tap plays: pleased for five seconds, turning right round once
  /// in [spinChance] of them.
  factory BotAnimation.tapped(math.Random random) => BotAnimation(
    mood: BotMood.happy,
    duration: tappedFor,
    spin: random.nextDouble() < spinChance,
  );

  static const tappedFor = Duration(seconds: 5);
  static const spinChance = 0.15;

  /// The spin starts once the first hop is under way and takes a little
  /// under a second.
  static const spinStart = Duration(milliseconds: 350);
  static const spinLength = Duration(milliseconds: 900);

  final BotMood mood;
  final Duration duration;
  final bool spin;

  /// The extra yaw [elapsed] in, radians: one eased full turn, then none,
  /// so the end of the spin is the pose it started from.
  double yawAt(Duration elapsed) {
    if (!spin) return 0;
    final u = (elapsed - spinStart).inMicroseconds / spinLength.inMicroseconds;
    if (u <= 0 || u >= 1) return 0;
    final eased = u < 0.5 ? 4 * u * u * u : 1 - math.pow(2 - 2 * u, 3) / 2;
    return 2 * math.pi * eased;
  }
}
