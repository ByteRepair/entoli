import "dart:math" as math;
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";

import "../../domain/bot_avatar/animation.dart";
import "../../domain/bot_avatar/frame.dart";
import "../../domain/bot_avatar/pose.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../domain/bot_avatar/volume.dart";
import "../widgets/picture_png.dart";

/// Whether the Bot Avatars below may move at all; on where nothing says. Off,
/// every avatar is a still with no ticker — what reduce-motion gives too,
/// without reaching anything but avatars. The test harness turns it off.
class BotAvatarMotion extends InheritedWidget {
  const BotAvatarMotion({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BotAvatarMotion>()?.enabled ??
      true;

  @override
  bool updateShouldNotify(BotAvatarMotion old) => old.enabled != enabled;
}

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

/// Where the user last pointed, anywhere in the app: one global pointer
/// route shared by every avatar that follows, held only while one does.
/// A mouse is followed wherever it goes until it leaves the window; a touch
/// is a place to glance at, counted by [touches] so each avatar can time
/// its own glance.
class _PointerWatch {
  _PointerWatch._();

  static final instance = _PointerWatch._();

  int _users = 0;

  /// The pointer's global position, or null where there is none to follow.
  Offset? position;

  /// [position] is a touch rather than a mouse.
  bool touch = false;
  int touches = 0;

  void attach() {
    if (_users++ == 0) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
    }
  }

  void detach() {
    if (--_users == 0) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
      position = null;
    }
  }

  void _route(PointerEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      if (event is PointerRemovedEvent) {
        if (!touch) position = null;
      } else if (event is PointerHoverEvent ||
          event is PointerMoveEvent ||
          event is PointerDownEvent) {
        position = event.position;
        touch = false;
      }
    } else if (event is PointerDownEvent &&
        event.kind != PointerDeviceKind.trackpad) {
      position = event.position;
      touch = true;
      touches++;
    }
  }
}

/// A Bot Avatar drawn with Flutter's canvas: a still, or a live one moving
/// in its [mood] on a ticker. The volume is built once per shape and cached
/// (see [PreparedBotAvatar]); a frame is a handful of projected polygons.
///
/// Live, it looks toward the pointer anywhere in the window and glances at
/// a touch, can be turned by a drag ([turnable]), and where [reactToTap]
/// a tap plays [BotAnimation.tapped] over its mood, timed on its own clock. It paints on a layer of its own, so a frame repaints the
/// avatar and not whatever it sits in. Under the platform's reduce-motion setting it holds a calm
/// pose, as the reference does, and does not spin.
///
/// A live avatar that is not painted does no work: a tick that finds the
/// last frame was never drawn — a row a list keeps built beyond its
/// viewport, an offstage page — stops the ticker, and the next paint, which
/// the undrawn frame leaves pending, starts it again.
class BotAvatarView extends StatefulWidget {
  const BotAvatarView({
    super.key,
    required this.spec,
    this.size = 36,
    this.mood = BotMood.idle,
    this.animate = true,
    this.turnable = false,
    this.reactToTap = false,
    this.view = ViewTurn.none,
    this.gaze,
    this.semanticLabel,
  });

  /// A still in the thumbnail pose: what a list of many draws, with no
  /// ticker per entry.
  const BotAvatarView.thumbnail({
    super.key,
    required this.spec,
    this.size = 56,
    this.semanticLabel,
  }) : mood = BotMood.idle,
       animate = false,
       turnable = false,
       reactToTap = false,
       view = thumbnailView,
       gaze = thumbnailGaze;

  final BotAvatarSpec spec;
  final double size;
  final BotMood mood;

  /// Moving on a ticker, looking toward the mouse wherever it is in the
  /// window and glancing at a touch for a moment — not while thinking, its
  /// look being its own then. False is one still frame.
  final bool animate;

  /// A drag turns it; a double tap turns it back.
  final bool turnable;

  /// A tap makes it happy for a while, and now and then spin.
  final bool reactToTap;

  /// A fixed extra turn and look, for stills.
  final ViewTurn view;
  final Gaze? gaze;

  /// Null names it after the definition; empty is decorative.
  final String? semanticLabel;

  @override
  State<BotAvatarView> createState() => _BotAvatarViewState();
}

class _BotAvatarViewState extends State<BotAvatarView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _animator = BotAnimator();
  late PreparedBotAvatar _prepared = PreparedBotAvatar.of(
    widget.spec.definition,
  );

  /// Made by the first [_sync], with the frame it would otherwise replace.
  ValueNotifier<BotAvatarFrame>? _frameOrNull;
  ValueNotifier<BotAvatarFrame> get _frame => _frameOrNull!;

  /// The avatar's clock: the ticker's elapsed time on top of what earlier
  /// spells of it banked before they were stopped.
  Duration _now = Duration.zero;
  Duration _banked = Duration.zero;

  /// The last frame set was painted; a tick that finds it was not stops the
  /// ticker, and the next paint starts it again.
  bool _painted = true;

  static final _random = math.Random();

  /// The animation a tap started, and when on [_now]'s clock; null once it
  /// has run its length.
  (BotAnimation, Duration)? _playing;

  /// The touch this view last saw, and until when it looks at it.
  int _seenTouch = 0;
  Duration _glanceUntil = Duration.zero;
  static const _glance = Duration(milliseconds: 2500);

  bool _watching = false;

  /// The turn a drag has given it.
  ViewTurn _turn = ViewTurn.none;
  Offset? _dragFrom;
  ViewTurn _turnFrom = ViewTurn.none;

  /// The platform's reduce-motion setting, read where it can change rather
  /// than on every tick.
  bool _reduced = false;

  BotMood get _mood => _playing?.$1.mood ?? widget.mood;

  /// Moving now: asked to and motion not reduced, or a reaction playing on
  /// a still. Under reduce-motion an avatar is always a still.
  bool get _live => !_reduced && (widget.animate || _playing != null);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced =
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
        !BotAvatarMotion.of(context);
    _sync();
  }

  @override
  void didUpdateWidget(BotAvatarView old) {
    super.didUpdateWidget(old);
    if (old.spec.definition != widget.spec.definition) {
      _prepared = PreparedBotAvatar.of(widget.spec.definition);
      _animator.reset();
    } else if (old.mood == widget.mood &&
        old.animate == widget.animate &&
        old.view == widget.view &&
        old.gaze == widget.gaze) {
      // A parent rebuilding over the same avatar — a streamed reply, a tap
      // beside it in a grid — changes nothing it draws.
      return;
    }
    _sync();
  }

  @override
  void dispose() {
    _watch(false);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _sync() {
    final live = _live;
    _watch(live);
    live ? _wake() : _sleep();
    // In build: no layout to place the pointer against yet.
    final next = live ? _render(look: false) : _still();
    final frame = _frameOrNull;
    frame == null ? _frameOrNull = ValueNotifier(next) : frame.value = next;
  }

  /// A tap's reaction: live while it plays — a still woken for it, and put
  /// back by the tick that sees it end.
  void _react() => setState(() {
    _playing = (BotAnimation.tapped(_random), _now);
    _sync();
  });

  void _watch(bool on) {
    if (on == _watching) return;
    _watching = on;
    if (on) {
      _PointerWatch.instance.attach();
      _seenTouch = _PointerWatch.instance.touches;
    } else {
      _PointerWatch.instance.detach();
    }
  }

  void _wake() {
    if (_ticker.isActive) return;
    _painted = true;
    _ticker.start();
  }

  void _sleep() {
    if (!_ticker.isActive) return;
    _banked = _now;
    _ticker.stop();
  }

  void _onPaint() {
    _painted = true;
    if (_ticker.isActive) return;
    // Asleep. Not from inside paint: the ticker starts once the frame is out.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && _live) _wake();
    });
  }

  BotAvatarFrame _still() => _prepared.frame(
    mood: _mood,
    reducedMotion: true,
    view: ViewTurn(
      widget.view.yaw + _turn.yaw,
      widget.view.pitch + _turn.pitch,
    ),
    gaze: _stillGaze(_mood, widget.gaze),
  );

  void _tick(Duration elapsed) {
    if (!_painted) {
      // Not drawn since the last frame: nothing on screen to move.
      _sleep();
      return;
    }
    _now = _banked + elapsed;
    _painted = false;
    _frame.value = _render();
    // A reaction on a still has ended: a still again.
    if (!_live) setState(_sync);
  }

  BotAvatarFrame _render({bool look = true}) {
    final ms = _now.inMicroseconds / 1000;
    if (_playing case (
      final played,
      final from,
    ) when _now - from >= played.duration) {
      _playing = null;
    }
    final spin = switch (_playing) {
      (final played, final from) => played.yawAt(_now - from),
      _ => 0.0,
    };
    final mood = _mood;
    final step = _animator.step(
      now: ms,
      mood: mood,
      target: look && mood != BotMood.thinking ? _target() : null,
      hold: _dragFrom != null,
    );
    return _prepared.frame(
      time: ms / 1000,
      mood: mood,
      gaze: step.gaze ?? widget.gaze,
      blend: step.blend,
      view: ViewTurn(
        widget.view.yaw + _turn.yaw + spin,
        widget.view.pitch + _turn.pitch,
      ),
    );
  }

  /// Where the pointer is, as a look from this avatar's eyes, or null where
  /// there is nothing to look at: no mouse in the window, or a touch whose
  /// glance is over.
  (double, double)? _target() {
    final watch = _PointerWatch.instance;
    if (watch.touches != _seenTouch) {
      _seenTouch = watch.touches;
      _glanceUntil = _now + _glance;
    }
    final at = watch.position;
    if (at == null || (watch.touch && _now >= _glanceUntil)) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final local = box.globalToLocal(at);
    final eyes = widget.spec.definition.eyes;
    final s = box.size;
    return pointerGaze(
      (x: local.dx, y: local.dy),
      (left: 0, top: 0, width: s.width, height: s.height),
      origin: (x: eyes.x / 100, y: eyes.y / 100),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    Widget child = CustomPaint(
      size: Size.square(widget.size),
      painter: BotAvatarPainter(
        frame: _frame,
        colour: Color(0xff000000 | spec.colour),
        outline: Theme.of(context).colorScheme.outline,
        onPaint: _live ? _onPaint : null,
      ),
    );
    final label = widget.semanticLabel ?? spec.definition.name;
    child = label.isEmpty
        ? ExcludeSemantics(child: child)
        : Semantics(label: label, image: true, child: child);
    if (_live) child = RepaintBoundary(child: child);
    if (widget.turnable && widget.animate) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _dragFrom = d.localPosition;
          _turnFrom = _turn;
        },
        onPanUpdate: (d) {
          final from = _dragFrom;
          if (from == null) return;
          final delta = d.localPosition - from;
          _turn = ViewTurn(
            _turnFrom.yaw + delta.dx * 0.011,
            (_turnFrom.pitch - delta.dy * 0.009).clamp(-0.9, 0.9),
          );
          // A still, under reduce-motion, is redrawn turned.
          if (!_ticker.isActive) _frame.value = _still();
        },
        onPanEnd: (_) => _dragFrom = null,
        onPanCancel: () => _dragFrom = null,
        onDoubleTap: () {
          _turn = ViewTurn.none;
          if (!_ticker.isActive) _frame.value = _still();
        },
        child: child,
      );
    }
    // Under reduce-motion there is no reaction to play: it stays a still.
    if (widget.reactToTap && !_reduced) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _react,
        child: child,
      );
    }
    return child;
  }
}

/// One still of [spec] as PNG bytes, [size] logical pixels square at
/// [pixelRatio], in the pose [BotAvatarView] holds as a still: for a surface
/// Flutter does not draw, the native shell's composer menu.
Future<Uint8List?> botAvatarPng(
  BotAvatarSpec spec, {
  required double size,
  required double pixelRatio,
  required Color outline,
}) async {
  final frame = ValueNotifier(
    PreparedBotAvatar.of(
      spec.definition,
    ).frame(reducedMotion: true, gaze: stillGaze),
  );
  try {
    return await pngOf(
      (size * pixelRatio).ceil(),
      (canvas) => BotAvatarPainter(
        frame: frame,
        colour: Color(0xff000000 | spec.colour),
        outline: outline,
      ).paint(canvas..scale(pixelRatio), Size.square(size)),
    );
  } finally {
    frame.dispose();
  }
}

/// Paints a [BotAvatarFrame] into its box: every cross-section in the body
/// colour, each eye in the ink, back to front. The 0..100 box fills the
/// canvas; a hop may draw a little past it, which is not clipped.
///
/// Where there is an [outline], the body's silhouette is drawn first in it,
/// grown by a hair, and the body over it: a thin edge around the whole
/// shape and none between its slices, so a white avatar on a white page
/// still has a shape. Grown in the canvas's pixels rather than stroked per
/// slice, since a slice's projection would stretch a stroke along with it.
class BotAvatarPainter extends CustomPainter {
  BotAvatarPainter({
    required this.frame,
    required this.colour,
    this.outline,
    this.onPaint,
  }) : _body = Paint()..color = colour,
       _edge = outline == null ? null : (Paint()..color = outline),
       super(repaint: frame);

  final ValueNotifier<BotAvatarFrame> frame;
  final Color colour;
  final Color? outline;
  final Paint _body;
  final Paint? _edge;
  static final _eyes = Paint()
    ..color = const Color(0xff000000 | BotAvatarSpec.ink);
  static final _arc = Paint()
    ..color = const Color(0xff000000 | BotAvatarSpec.ink)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  /// One path every happy eye is drawn into: an arc's bend moves every
  /// frame, so there is nothing to keep, and the recording copies it.
  static final _arcPath = ui.Path();

  /// Told each time a frame is drawn: a live view's proof it is on screen.
  final VoidCallback? onPaint;

  /// Each cross-section's path, built the first time it is drawn and held
  /// by its loops: a level's front and back copies share theirs, and so one
  /// path; the loops belong to a cached volume, so this lives as long as that
  /// does.
  static final _paths = Expando<ui.Path>("bot-avatar-slice");

  static ui.Path _pathOf(VolumeSlice slice) => _paths[slice.loops] ??= () {
    final path = ui.Path()
      ..fillType = slice.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
    for (final loop in slice.loops) {
      path.addPolygon([for (final (x, y) in loop) Offset(x, y)], true);
    }
    return path;
  }();

  /// One 4×4 the affines are written into: `Canvas.transform` copies it,
  /// so a frame's hundred slices need no matrix of their own.
  static final _scratch = Float64List(16)
    ..[10] = 1
    ..[15] = 1;

  static Float64List _matrix(Affine m) => _scratch
    ..[0] = m.a
    ..[1] = m.b
    ..[4] = m.c
    ..[5] = m.d
    ..[12] = m.e
    ..[13] = m.f;

  /// How far the outline stands out from the body, in logical pixels: a
  /// hair at every size, a little less on the smallest.
  static double _edgeWidth(Size size) =>
      (size.shortestSide * 0.012).clamp(0.5, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    onPaint?.call();
    final f = frame.value;
    if (_edge case final edge?) {
      final grow = _edgeWidth(size);
      canvas.saveLayer(
        // Room for a hop past the box, which is not clipped either.
        (Offset.zero & size).inflate(size.shortestSide * 0.25),
        Paint()
          ..imageFilter = ui.ImageFilter.dilate(radiusX: grow, radiusY: grow),
      );
      _draw(canvas, size, f, edge);
      canvas.restore();
    }
    _draw(canvas, size, f, null);
  }

  /// The frame's shapes, back to front; with a [silhouette], the body alone,
  /// all of it in that paint.
  void _draw(Canvas canvas, Size size, BotAvatarFrame f, Paint? silhouette) {
    canvas
      ..save()
      ..scale(size.width / 100, size.height / 100)
      ..transform(_matrix(f.root));
    for (final shape in f.shapes) {
      if (silhouette != null && shape is! SliceShape) continue;
      canvas
        ..save()
        ..transform(_matrix(shape.matrix));
      switch (shape) {
        case SliceShape(:final slice):
          canvas.drawPath(_pathOf(slice), silhouette ?? _body);
        case EyeShapeMark(
          mark: PillMark(
            :final x,
            :final y,
            :final width,
            :final height,
            :final radius,
          ),
        ):
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, y, width, height),
              Radius.circular(radius),
            ),
            _eyes,
          );
        case EyeShapeMark(mark: final ArcMark arc):
          canvas.drawPath(
            _arcPath
              ..reset()
              ..moveTo(arc.x0, arc.y)
              ..quadraticBezierTo(arc.cx, arc.cy, arc.x1, arc.y),
            _arc..strokeWidth = arc.strokeWidth,
          );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BotAvatarPainter old) =>
      old.frame != frame ||
      old.colour != colour ||
      old.outline != outline ||
      old.onPaint != onPaint;
}
