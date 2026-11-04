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

/// How a thumbnail stands: turned a little right, tipped up, looking up and
/// right, so a grid of them faces one way. The reference editor's pose.
const thumbnailView = ViewTurn(0.5, 0.12);
const thumbnailGaze = Gaze(0.7, -1);

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

  /// What the last live frame was drawn from under reduced motion, where a
  /// frame is a pure function of it: an equal one is the same picture.
  Object? _reducedInputs;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
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
    _frameOrNull?.dispose();
    super.dispose();
  }

  void _sync() {
    _watch(widget.animate);
    widget.animate ? _wake() : _sleep();
    _reducedInputs = null;
    // In build: no layout to place the pointer against yet.
    final next = widget.animate ? _render(look: false)! : _still();
    final frame = _frameOrNull;
    frame == null ? _frameOrNull = ValueNotifier(next) : frame.value = next;
  }

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
      if (mounted && widget.animate) _wake();
    });
  }

  BotAvatarFrame _still() => _prepared.frame(
    mood: widget.mood,
    reducedMotion: true,
    view: widget.view,
    gaze: widget.gaze,
  );

  void _tick(Duration elapsed) {
    if (!_painted) {
      // Not drawn since the last frame: nothing on screen to move.
      _sleep();
      return;
    }
    _now = _banked + elapsed;
    final next = _render();
    if (next == null) return;
    _painted = false;
    _frame.value = next;
  }

  /// The frame now, or null where it would be the one on screen.
  BotAvatarFrame? _render({bool look = true}) {
    final ms = _now.inMicroseconds / 1000;
    final reduced = _reduced;
    if (_playing case (
      final played,
      final from,
    ) when _now - from >= played.duration) {
      _playing = null;
    }
    final spin = switch (_playing) {
      (final played, final from) when !reduced => played.yawAt(_now - from),
      _ => 0.0,
    };
    final mood = _mood;
    final step = _animator.step(
      now: ms,
      mood: mood,
      target: look && mood != BotMood.thinking ? _target() : null,
      hold: _dragFrom != null,
      reducedMotion: reduced,
    );
    if (reduced) {
      // Reduced motion holds the pose still, so the frame changes only with
      // the look, the mood or the turn.
      final inputs = (step.gaze, mood, _turn.yaw, _turn.pitch);
      if (inputs == _reducedInputs) return null;
      _reducedInputs = inputs;
    }
    return _prepared.frame(
      time: ms / 1000,
      mood: mood,
      gaze: step.gaze ?? widget.gaze,
      blend: step.blend,
      view: ViewTurn(
        widget.view.yaw + _turn.yaw + spin,
        widget.view.pitch + _turn.pitch,
      ),
      reducedMotion: reduced,
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
        onPaint: widget.animate ? _onPaint : null,
      ),
    );
    final label = widget.semanticLabel ?? spec.definition.name;
    child = label.isEmpty
        ? ExcludeSemantics(child: child)
        : Semantics(label: label, image: true, child: child);
    if (!widget.animate) return child;
    child = RepaintBoundary(child: child);
    if (widget.turnable) {
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
        },
        onPanEnd: (_) => _dragFrom = null,
        onPanCancel: () => _dragFrom = null,
        onDoubleTap: () => _turn = ViewTurn.none,
        child: child,
      );
    }
    if (widget.reactToTap) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _playing = (BotAnimation.tapped(_random), _now),
        child: child,
      );
    }
    return child;
  }
}

/// Paints a [BotAvatarFrame] into its box: every cross-section in the body
/// colour, each eye in the ink, back to front. The 0..100 box fills the
/// canvas; a hop may draw a little past it, which is not clipped.
class BotAvatarPainter extends CustomPainter {
  BotAvatarPainter({required this.frame, required this.colour, this.onPaint})
    : _body = Paint()..color = colour,
      super(repaint: frame);

  final ValueNotifier<BotAvatarFrame> frame;
  final Color colour;
  final Paint _body;
  static final _eyes = Paint()
    ..color = const Color(0xff000000 | BotAvatarSpec.ink);
  static final _arc = Paint()
    ..color = const Color(0xff000000 | BotAvatarSpec.ink)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

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

  @override
  void paint(Canvas canvas, Size size) {
    onPaint?.call();
    final f = frame.value;
    canvas
      ..save()
      ..scale(size.width / 100, size.height / 100)
      ..transform(_matrix(f.root));
    for (final shape in f.shapes) {
      canvas
        ..save()
        ..transform(_matrix(shape.matrix));
      switch (shape) {
        case SliceShape(:final slice):
          canvas.drawPath(_pathOf(slice), _body);
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
            ui.Path()
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
      old.frame != frame || old.colour != colour || old.onPaint != onPaint;
}
