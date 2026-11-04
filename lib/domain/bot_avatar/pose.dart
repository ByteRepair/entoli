// How a Bot Avatar moves: a pose is a pure function of the avatar's seed, the
// clock, its mood and where it looks — no wall clock and no randomness, so
// any frame can be drawn again exactly. A port of Open Bot Avatar's
// `motion.ts`, `mood.ts`, `follow.ts` and `animator.ts` (MIT).
import "dart:math" as math;

/// What the avatar is doing: at rest, working something out, or pleased.
enum BotMood {
  idle("Idle"),
  thinking("Thinking"),
  happy("Happy");

  const BotMood(this.label);

  final String label;
}

enum EyeShape { pill, happy }

/// One moment of an avatar's motion.
class Pose {
  Pose({
    required this.yaw,
    required this.pitch,
    this.roll = 0,
    this.lift = 0,
    this.sx = 1,
    this.sy = 1,
    this.gazeX = 0,
    this.gazeY = 0,
    this.blink = 0,
    this.squintL = 0,
    this.squintR = 0,
    this.eyeShape = EyeShape.pill,
  });

  /// The view's turn about the vertical axis and tip about the horizontal,
  /// radians.
  double yaw, pitch;

  /// In-plane rotation, degrees.
  double roll;

  /// Vertical offset, negative up, box units.
  double lift;

  /// Squash and stretch about the foot of the body.
  double sx, sy;

  /// Where the eyes look, −1..1 per axis.
  double gazeX, gazeY;

  /// 0 open, 1 shut.
  double blink;

  /// Extra lid narrowing per eye, 0..1.
  double squintL, squintR;

  EyeShape eyeShape;
}

/// A look target, −1..1 per axis (x right, y down), faded in by [weight].
class Gaze {
  const Gaze(this.x, this.y, [this.weight = 1]);
  final double x, y, weight;
}

/// An extra turn on top of the resting view, radians.
class ViewTurn {
  const ViewTurn(this.yaw, this.pitch);

  static const none = ViewTurn(0, 0);

  final double yaw, pitch;
}

/// A mood easing in over what was shown before it: a plain mood, or one
/// itself still easing in with its progress frozen. [t] runs 0..1.
class MoodBlend {
  const MoodBlend(this.from, this.t);
  final MoodState from;
  final double t;
}

/// A mood on screen, possibly still easing in over what came before.
class MoodState {
  const MoodState(this.mood, [this.blend]);
  final BotMood mood;
  final MoodBlend? blend;

  /// What a new change eases in from: this state with any change under way
  /// frozen where it is. Changes whose share has all but faded, or past a
  /// few levels, are dropped, so quick switching never grows the chain.
  MoodState settled([double share = 1, int depth = 0]) {
    final b = blend;
    if (b == null) return this;
    final rest = share * (1 - b.t);
    if (rest < 0.02 || depth >= 3) return MoodState(mood);
    return MoodState(mood, MoodBlend(b.from.settled(rest, depth + 1), b.t));
  }
}

/// The resting view: turned a little and seen a little from above.
const baseYaw = -0.3;
const basePitch = 0.2;

/// How far the body turns toward a look target, and the eyes' share.
const _lookYaw = 0.32;
const _lookPitch = 0.18;

/// Tipping down toward a target below, more than [_lookPitch]: the resting
/// view is already tipped up, so the reference's symmetric tip barely left
/// level when looking down. Not the reference's — it has one constant.
const _lookPitchDown = 0.45;
const _lookEyes = 0.7;

const _tau = math.pi * 2;

/// Length of a mood change, milliseconds.
const moodMs = 420;

int _imul(int a, int b) => (a * b) & 0xffffffff;

/// FNV-1a over the string's UTF-16 units, as the reference hashes ids.
int hashString(String s) {
  var h = 2166136261;
  for (final c in s.codeUnits) {
    h ^= c;
    h = _imul(h, 16777619);
  }
  return h & 0xffffffff;
}

/// Stateless hash noise in [0, 1).
double noise(int seed, int n) {
  var h = (seed ^ _imul(n, 0x9e3779b1)) & 0xffffffff;
  h = _imul(h ^ (h >> 16), 0x85ebca6b);
  h = _imul(h ^ (h >> 13), 0xc2b2ae35);
  h ^= h >> 16;
  return (h & 0xffffffff) / 4294967296;
}

double _smooth(double u) {
  final x = u.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

/// Eased progress of a mood change [elapsedMs] in.
double moodProgress(double elapsedMs) => _smooth(elapsedMs / moodMs);

/// Blink closure 0..1: one per ~4.2 s slot at a seeded offset, sometimes
/// twice.
double _blinkAt(int seed, double t) {
  const slot = 4.2, dur = 0.19;
  final s0 = (t / slot).floor();
  var closure = 0.0;
  void blinkFrom(double b) {
    final u = (t - b) / dur;
    if (u > 0 && u < 1) closure = math.max(closure, math.sin(math.pi * u));
  }

  for (var s = s0 - 1; s <= s0; s++) {
    final start = s * slot + 0.5 + noise(seed, s * 2) * 2.9;
    blinkFrom(start);
    if (noise(seed, s * 2 + 1) > 0.8) blinkFrom(start + 0.34);
  }
  return closure;
}

/// Idle eye wander: short holds between quick saccades, centred more often
/// than not.
(double, double) _wanderAt(int seed, double t) {
  const slot = 1.9;
  final s = (t / slot).floor();
  (double, double) target(int k) {
    if (noise(seed, 1000 + k * 3) < 0.4) return (0, 0);
    return (
      (noise(seed, 1001 + k * 3) * 2 - 1) * 0.6,
      (noise(seed, 1002 + k * 3) * 2 - 1) * 0.35,
    );
  }

  final a = target(s - 1), b = target(s);
  final e = _smooth((t - s * slot) / 0.16);
  return (a.$1 + (b.$1 - a.$1) * e, a.$2 + (b.$2 - a.$2) * e);
}

/// The pose part way from [a] to [b]. A change of eye shape swaps halfway,
/// inside a blink.
Pose blendPoses(Pose a, Pose b, double t) {
  final k = t.clamp(0.0, 1.0);
  double mix(double x, double y) => x + (y - x) * k;
  final pose = Pose(
    yaw: mix(a.yaw, b.yaw),
    pitch: mix(a.pitch, b.pitch),
    roll: mix(a.roll, b.roll),
    lift: mix(a.lift, b.lift),
    sx: mix(a.sx, b.sx),
    sy: mix(a.sy, b.sy),
    gazeX: mix(a.gazeX, b.gazeX),
    gazeY: mix(a.gazeY, b.gazeY),
    blink: mix(a.blink, b.blink),
    squintL: mix(a.squintL, b.squintL),
    squintR: mix(a.squintR, b.squintR),
    eyeShape: b.eyeShape,
  );
  if (a.eyeShape != b.eyeShape) {
    pose.eyeShape = k < 0.5 ? a.eyeShape : b.eyeShape;
    pose.blink = math.max(pose.blink, 1 - (2 * k - 1).abs());
  }
  return pose;
}

/// The pose at [time] seconds.
Pose computePose({
  required int seed,
  required double time,
  required BotMood mood,
  Gaze? gaze,
  bool reducedMotion = false,
  ViewTurn view = ViewTurn.none,
  MoodBlend? blend,
}) {
  final pose = _moodPose(seed, time, mood, gaze, reducedMotion, view);
  if (blend == null || !(blend.t < 1)) return pose;
  final from = computePose(
    seed: seed,
    time: time,
    mood: blend.from.mood,
    gaze: gaze,
    reducedMotion: reducedMotion,
    view: view,
    blend: blend.from.blend,
  );
  return blendPoses(from, pose, blend.t.isFinite ? blend.t : 1);
}

Pose _moodPose(
  int seed,
  double time,
  BotMood mood,
  Gaze? gaze,
  bool reduced,
  ViewTurn view,
) {
  // A per-avatar phase, so several on one screen do not move in lockstep.
  final t = reduced ? 0.0 : time + noise(seed, 7) * 10;
  double wave(double period, [double phase = 0]) =>
      reduced ? 0 : math.sin(_tau * t / period + phase);
  final given = gaze != null && gaze.x.isFinite && gaze.y.isFinite
      ? (gaze.x.clamp(-1.0, 1.0), gaze.y.clamp(-1.0, 1.0))
      : null;
  final weight = given != null
      ? (gaze!.weight.isFinite ? gaze.weight.clamp(0.0, 1.0) : 1.0)
      : 0.0;
  // While it attends to a target the body holds its aim.
  final sway = 1 - 0.7 * weight;

  final pose = Pose(yaw: baseYaw, pitch: basePitch);
  switch (mood) {
    case BotMood.happy:
      const period = 0.92;
      final p = reduced ? 0.5 : ((t % period) + period) % period / period;
      final air = 4 * p * (1 - p);
      final land = reduced
          ? 0.0
          : (1 - math.min(p, 1 - p) / 0.12).clamp(0.0, 1.0);
      final moving = reduced ? 0.0 : 1.0;
      pose
        ..lift = reduced ? 0 : -3.2 * air
        ..sy = 1 - 0.09 * land + 0.03 * air * moving
        ..sx = 1 + 0.07 * land - 0.015 * air * moving
        ..roll = 4.5 * wave(period * 2)
        ..yaw += 0.1 * wave(period * 2, 0.6)
        ..eyeShape = EyeShape.happy;
    case BotMood.thinking:
      pose
        ..yaw += 0.12 + 0.05 * sway * wave(7.3)
        ..pitch += 0.08
        ..roll = -5 + 1.4 * wave(4.1)
        ..lift = reduced ? 0 : -0.5 * (1 - math.cos(_tau * t / 5.2))
        ..gazeX = 0.55 + 0.3 * wave(5.6)
        ..gazeY = -0.8
        ..squintL = 0.22
        ..squintR = 0.32 + 0.1 * wave(3.1);
      if (!reduced) pose.blink = _blinkAt(seed, t * 0.7);
    case BotMood.idle:
      pose
        ..yaw += 0.07 * sway * wave(6.1)
        ..pitch += 0.04 * sway * wave(4.7, 1)
        ..roll = 1.6 * wave(5.3, 2)
        ..lift = reduced ? 0 : -0.45 * (1 - math.cos(_tau * t / 3.4));
      final breath = wave(3.4, -math.pi / 2);
      pose
        ..sy = 1 + 0.012 * breath
        ..sx = 1 - 0.008 * breath;
      if (!reduced) {
        pose.blink = _blinkAt(seed, t);
        final (x, y) = _wanderAt(seed, t);
        pose
          ..gazeX = x
          ..gazeY = y;
      }
  }

  if (given != null && weight > 0) {
    // A look target wins over the wander: the body turns to face it and the
    // eyes add a share on top. Reduced motion keeps the body still.
    double mix(double a, double b) => a + (b - a) * weight;
    final share = reduced ? 1.0 : _lookEyes;
    if (pose.eyeShape == EyeShape.pill) {
      pose
        ..gazeX = mix(pose.gazeX, given.$1 * share)
        ..gazeY = mix(pose.gazeY, given.$2 * share);
    }
    if (!reduced) {
      final tip = given.$2 > 0 ? _lookPitchDown : _lookPitch;
      pose
        ..yaw += weight * (given.$1 * _lookYaw - baseYaw)
        ..pitch += weight * (-given.$2 * tip - basePitch / 2);
    }
  }
  if (view.yaw.isFinite && view.pitch.isFinite) {
    pose
      ..yaw += view.yaw
      ..pitch += view.pitch;
  }
  return pose;
}

/// The eased look toward a pointer: [attention] fades the whole response,
/// so following hands over to idle motion without a jump.
class _Follow {
  const _Follow(this.x, this.y, this.attention);
  static const rest = _Follow(0, 0, 0);
  final double x, y, attention;
}

/// The look direction, −1..1, toward [pointer] from the avatar's eyes in a
/// [box] of [size] — radial and soft, so it uses the range near the avatar
/// and saturates gently past it.
(double, double) pointerGaze(
  ({double x, double y}) pointer,
  ({double left, double top, double width, double height}) box, {
  ({double x, double y}) origin = (x: 0.5, y: 0.5),
}) {
  final reach = math.max(math.max(box.width, box.height), 160.0);
  final dx = (pointer.x - (box.left + box.width * origin.x)) / reach;
  final dy = (pointer.y - (box.top + box.height * origin.y)) / reach;
  final m = math.sqrt(dx * dx + dy * dy);
  if (!m.isFinite || m < 1e-9) return (0, 0);
  final k = _tanh(m) / m;
  return (dx * k, dy * k);
}

double _tanh(double x) {
  if (x > 20) return 1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// What an [BotAnimator] step hands the renderer for one frame.
class AnimatorStep {
  const AnimatorStep(this.gaze, this.blend);
  final Gaze? gaze;
  final MoodBlend? blend;
}

/// The state a live avatar keeps between frames: the eased look toward a
/// target and the eased change between moods. Fed once a frame.
class BotAnimator {
  _Follow _follow = _Follow.rest;
  double? _last;
  MoodState? _mood;
  double _since = 0;

  /// [now] is a wall clock in milliseconds; [target] null eases back to
  /// rest; [hold] keeps the look where it is.
  AnimatorStep step({
    required double now,
    required BotMood mood,
    (double, double)? target,
    bool hold = false,
  }) {
    final dt = _last == null ? 0.0 : (now - _last!) / 1000;
    _last = now;
    if (!hold) _follow = _followStep(_follow, target, dt);

    final current = _mood;
    if (current != null && mood != current.mood) {
      final shown = MoodState(
        current.mood,
        current.blend == null
            ? null
            : MoodBlend(current.blend!.from, moodProgress(now - _since)),
      );
      _mood = MoodState(mood, MoodBlend(shown.settled(), 0));
      _since = now;
    }
    if (_mood == null) {
      _mood = MoodState(mood);
      _since = now;
    }
    final t = moodProgress(now - _since);
    MoodBlend? blend;
    final from = _mood!.blend;
    if (from != null && t < 1) {
      blend = MoodBlend(from.from, t);
    } else {
      _mood = MoodState(_mood!.mood);
    }
    return AnimatorStep(_gaze(_follow), blend);
  }

  /// Back to rest with no mood history, as for a new shape.
  void reset() {
    _follow = _Follow.rest;
    _last = null;
    _mood = null;
  }

  static Gaze? _gaze(_Follow s) {
    final a = s.attention.clamp(0.0, 1.0);
    return a > 0 ? Gaze(s.x, s.y, a * a * (3 - 2 * a)) : null;
  }

  /// One easing step toward [target], landing on it once within a hair.
  static _Follow _followStep(
    _Follow state,
    (double, double)? target,
    double dt,
  ) {
    const tau = 0.12, attendTau = 0.3;
    final goal = target == null
        ? _Follow.rest
        : _Follow(target.$1, target.$2, 1);
    final step = dt.clamp(0.0, 0.1);
    double ease(double tau) => 1 - math.exp(-step / tau);
    // Losing the target relaxes the look at the unhurried rate.
    final k = ease(target != null ? tau : attendTau);
    final next = _Follow(
      state.x + (goal.x - state.x) * k,
      state.y + (goal.y - state.y) * k,
      state.attention + (goal.attention - state.attention) * ease(attendTau),
    );
    final moving =
        (goal.x - next.x).abs() > 0.002 ||
        (goal.y - next.y).abs() > 0.002 ||
        (goal.attention - next.attention).abs() > 0.002;
    return moving ? next : goal;
  }
}
