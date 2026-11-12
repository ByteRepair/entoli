import "dart:math" as math;

import "../../domain/bot_avatar/animation.dart";
import "../../domain/bot_avatar/definition.dart";
import "../../domain/bot_avatar/frame.dart";
import "../../domain/bot_avatar/pose.dart";

/// How a thumbnail stands: turned a little right, tipped up, looking up and
/// right, so a grid of them faces one way. The reference editor's pose.
const thumbnailView = ViewTurn(0.5, 0.12);
const thumbnailGaze = Gaze(0.7, -1);

/// Where an idle still looks when nothing gives it a look: down and to the
/// right, so a face at rest reads as reading the page beside it rather than
/// staring out of it. Thinking keeps its own look; happy eyes are arcs.
const stillGaze = Gaze(0.7, 0.7);

Gaze? _stillGaze(BotMood mood, Gaze? given) =>
    given ?? (mood == BotMood.idle ? stillGaze : null);

/// One avatar on screen, as every frontend animates it: its mood eased from
/// the last, the reaction a tap plays — happy for a while, now and then a
/// spin — and the frame for a moment on its own clock. A frontend keeps the
/// clock, the pointer and the drag, and draws what this returns.
class BotActor {
  BotActor(BotAvatarDefinition definition, {math.Random? random})
    : _prepared = PreparedBotAvatar.of(definition),
      _random = random ?? math.Random();

  PreparedBotAvatar _prepared;
  final math.Random _random;
  final _animator = BotAnimator();

  /// The animation a tap started, and when on the caller's clock; null once
  /// it has run its length.
  (BotAnimation, Duration)? _playing;

  BotAvatarDefinition get definition => _prepared.definition;

  /// A new shape starts from rest, with no mood history.
  set definition(BotAvatarDefinition value) {
    if (value == _prepared.definition) return;
    _prepared = PreparedBotAvatar.of(value);
    _animator.reset();
  }

  /// What it shows: the reaction while one plays, else [mood].
  BotMood moodOver(BotMood mood) => _playing?.$1.mood ?? mood;

  /// Whether a tap's reaction is playing at [now].
  bool reactingAt(Duration now) {
    final playing = _playing;
    if (playing == null) return false;
    if (now - playing.$2 >= playing.$1.duration) {
      _playing = null;
      return false;
    }
    return true;
  }

  /// A tap at [now]: the reaction starts, or starts over.
  void tap(Duration now) => _playing = (BotAnimation.tapped(_random), now);

  /// The frame at [now] in [mood], easing toward [target] — a look from its
  /// eyes, −1..1 — or holding the look where [hold]. [view] is a turn on top
  /// of the resting one, a drag's or a still's.
  BotAvatarFrame frame(
    Duration now, {
    BotMood mood = BotMood.idle,
    (double, double)? target,
    bool hold = false,
    ViewTurn view = ViewTurn.none,
    Gaze? gaze,
  }) {
    final ms = now.inMicroseconds / 1000;
    final spin = reactingAt(now) ? _playing!.$1.yawAt(now - _playing!.$2) : 0.0;
    final shown = moodOver(mood);
    final step = _animator.step(
      now: ms,
      mood: shown,
      target: target,
      hold: hold,
    );
    return _prepared.frame(
      time: ms / 1000,
      mood: shown,
      gaze: step.gaze ?? _stillGaze(shown, gaze),
      blend: step.blend,
      view: ViewTurn(view.yaw + spin, view.pitch),
    );
  }

  /// One still frame in [mood], turned by [view]: what a reduced-motion
  /// avatar, a thumbnail or a picture shows.
  BotAvatarFrame still({
    BotMood mood = BotMood.idle,
    ViewTurn view = ViewTurn.none,
    Gaze? gaze,
  }) {
    final shown = moodOver(mood);
    return _prepared.frame(
      mood: shown,
      reducedMotion: true,
      view: view,
      gaze: _stillGaze(shown, gaze),
    );
  }
}
