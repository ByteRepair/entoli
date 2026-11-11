import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/bot_avatar/definition.dart";
import "../../domain/bot_avatar/frame.dart";
import "../../domain/bot_avatar/pose.dart";
import "../../domain/bot_avatar/volume.dart";
import "actor.dart";

/// The Bot Avatars a client draws but does not animate: the core poses each
/// one and hands over frames, the client drawing them from geometry it was
/// sent once. A definition is handed out by key — its id and its value's
/// hash, so an import and an agent's older copy of it stay apart — and each
/// live avatar is an instance, a [BotActor] on the client's clock.
class BotStage {
  final _definitions = <String, BotAvatarDefinition>{};
  final _slices = <String, Map<VolumeSlice, int>>{};
  final _actors = <String, BotActor>{};

  String keyOf(BotAvatarDefinition definition) {
    final key = "${definition.id}#${definition.hashCode & 0xffffffff}";
    _definitions[key] = definition;
    return key;
  }

  BotAvatarDefinition? definition(String key) => _definitions[key];

  /// [key]'s slices, the shapes a frame names by place: a count, then per
  /// slice its fill rule (1 even-odd, 0 nonzero), a loop count, and per loop
  /// a point count and its x y pairs, in the 0..100 box. Null for a key
  /// never handed out.
  Float64List? geometry(String key) {
    final definition = _definitions[key];
    if (definition == null) return null;
    final slices = _sliceIndex(key, definition);
    final out = <double>[slices.length.toDouble()];
    for (final s in slices.keys) {
      out
        ..add(s.evenOdd ? 1 : 0)
        ..add(s.loops.length.toDouble());
      for (final loop in s.loops) {
        out.add(loop.length.toDouble());
        for (final (x, y) in loop) {
          out.addAll([x, y]);
        }
      }
    }
    return Float64List.fromList(out);
  }

  Map<VolumeSlice, int> _sliceIndex(String key, BotAvatarDefinition d) =>
      _slices[key] ??= () {
        final index = <VolumeSlice, int>{};
        for (final part in PreparedBotAvatar.of(d).volume.parts) {
          for (final s in [...part.zSlices, ...part.xSlices]) {
            index.putIfAbsent(s, () => index.length);
          }
        }
        return index;
      }();

  /// The frame of [instance], wearing [key], at [now] on its own clock
  /// ([encodeFrame]): moving where [live], else the still — or the
  /// thumbnail's pose where [thumbnail]. [turn] is a drag's. [pointer] is
  /// where the pointer is over the avatar's [size]-square box, its origin
  /// the box's top left, which a live avatar looks toward; null where there
  /// is none to follow.
  Float64List? frame(
    String instance,
    String key, {
    required Duration now,
    BotMood mood = BotMood.idle,
    bool live = true,
    bool thumbnail = false,
    ViewTurn turn = ViewTurn.none,
    (double, double)? pointer,
    double size = 0,
  }) {
    final definition = _definitions[key];
    if (definition == null) return null;
    final actor = _actors[instance] ??= BotActor(definition);
    actor.definition = definition;
    final frame = thumbnail
        ? actor.still(view: thumbnailView, gaze: thumbnailGaze)
        : live || actor.reactingAt(now)
        ? actor.frame(
            now,
            mood: mood,
            view: turn,
            target: pointer == null || size <= 0
                ? null
                : pointerGaze(
                    (x: pointer.$1, y: pointer.$2),
                    (left: 0, top: 0, width: size, height: size),
                    origin: (
                      x: definition.eyes.x / 100,
                      y: definition.eyes.y / 100,
                    ),
                  ),
          )
        : actor.still(mood: mood, view: turn);
    return encodeFrame(
      frame,
      _sliceIndex(key, definition),
      reacting: actor.reactingAt(now),
    );
  }

  /// A tap on [instance] at [now]: it reacts, live while the reaction plays.
  void tap(String instance, Duration now) => _actors[instance]?.tap(now);

  /// [instance] is off screen for good.
  void drop(String instance) => _actors.remove(instance);
}

/// The app's one [BotStage].
final botStageProvider = Provider<BotStage>((ref) => BotStage());

/// [frame] as numbers: whether a tap's reaction is playing (1 or 0), so a
/// still is drawn live until it ends; its root matrix (a b c d e f, SVG order), a shape
/// count, then per shape thirteen numbers — its kind, six of what it is, and
/// its matrix. A slice (kind 0) is its place in [slices]; an open eye (1)
/// is x, y, width, height, radius; a happy eye (2) is x0, x1, y, cx, cy,
/// stroke width. Back to front, in the 0..100 box.
Float64List encodeFrame(
  BotAvatarFrame frame,
  Map<VolumeSlice, int> slices, {
  bool reacting = false,
}) {
  final out = Float64List(8 + 13 * frame.shapes.length);
  var at = 0;
  void put(double v) => out[at++] = v;
  void affine(Affine m) {
    put(m.a);
    put(m.b);
    put(m.c);
    put(m.d);
    put(m.e);
    put(m.f);
  }

  put(reacting ? 1 : 0);
  affine(frame.root);
  put(frame.shapes.length.toDouble());
  for (final shape in frame.shapes) {
    switch (shape) {
      case SliceShape(:final slice):
        put(0);
        put((slices[slice] ?? -1).toDouble());
        at += 5;
      case EyeShapeMark(
        mark: PillMark(
          :final x,
          :final y,
          :final width,
          :final height,
          :final radius,
        ),
      ):
        put(1);
        put(x);
        put(y);
        put(width);
        put(height);
        put(radius);
        put(0);
      case EyeShapeMark(
        mark: ArcMark(
          :final x0,
          :final x1,
          :final y,
          :final cx,
          :final cy,
          :final strokeWidth,
        ),
      ):
        put(2);
        put(x0);
        put(x1);
        put(y);
        put(cx);
        put(cy);
        put(strokeWidth);
    }
    affine(shape.matrix);
  }
  return out;
}
