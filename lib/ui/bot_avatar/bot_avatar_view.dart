import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";

import "../../domain/bot_avatar/frame.dart";
import "../../domain/bot_avatar/pose.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../domain/bot_avatar/volume.dart";

/// How a thumbnail stands: turned a little right, tipped up, looking up and
/// right, so a grid of them faces one way. The reference editor's pose.
const thumbnailView = ViewTurn(0.5, 0.12);
const thumbnailGaze = Gaze(0.7, -1);

/// A Bot Avatar drawn with Flutter's canvas: a still, or a live one moving
/// in its [mood] on a ticker. The volume is built once per shape and cached
/// (see [PreparedBotAvatar]); a frame is a handful of projected polygons.
///
/// Live, it can follow the pointer with its eyes and body
/// ([followPointer]) and be turned by a drag ([turnable]). Under the
/// platform's reduce-motion setting it holds a calm pose, as the reference
/// does.
class BotAvatarView extends StatefulWidget {
  const BotAvatarView({
    super.key,
    required this.spec,
    this.size = 36,
    this.mood = BotMood.idle,
    this.animate = true,
    this.followPointer = false,
    this.turnable = false,
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
       followPointer = false,
       turnable = false,
       view = thumbnailView,
       gaze = thumbnailGaze;

  final BotAvatarSpec spec;
  final double size;
  final BotMood mood;

  /// Moving on a ticker; false is one still frame.
  final bool animate;

  /// Look toward a hovering pointer (desktop) or a touch.
  final bool followPointer;

  /// A drag turns it; a double tap turns it back.
  final bool turnable;

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
  late final ValueNotifier<BotAvatarFrame> _frame = ValueNotifier(_still());
  Duration _elapsed = Duration.zero;

  /// The look target from the pointer, −1..1, or null.
  (double, double)? _target;
  ViewTurn _turn = ViewTurn.none;
  Offset? _dragFrom;
  ViewTurn _turnFrom = ViewTurn.none;

  PreparedBotAvatar get _prepared =>
      PreparedBotAvatar.of(widget.spec.definition);

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(BotAvatarView old) {
    super.didUpdateWidget(old);
    if (old.spec.definition != widget.spec.definition) _animator.reset();
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _sync() {
    if (widget.animate) {
      if (!_ticker.isActive) _ticker.start();
      _frame.value = _render(_elapsed);
    } else {
      if (_ticker.isActive) _ticker.stop();
      _frame.value = _still();
    }
  }

  BotAvatarFrame _still() => _prepared.frame(
    mood: widget.mood,
    reducedMotion: true,
    view: widget.view,
    gaze: widget.gaze,
  );

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    _frame.value = _render(elapsed);
  }

  BotAvatarFrame _render(Duration elapsed) {
    final ms = elapsed.inMicroseconds / 1000;
    final reduced = _reduced;
    final step = _animator.step(
      now: ms,
      mood: widget.mood,
      target: _target,
      hold: _dragFrom != null,
      reducedMotion: reduced,
    );
    return _prepared.frame(
      time: ms / 1000,
      mood: widget.mood,
      gaze: step.gaze ?? widget.gaze,
      blend: step.blend,
      view: ViewTurn(
        widget.view.yaw + _turn.yaw,
        widget.view.pitch + _turn.pitch,
      ),
      reducedMotion: reduced,
    );
  }

  void _look(Offset local) {
    final eyes = widget.spec.definition.eyes;
    final s = widget.size;
    _target = pointerGaze(
      (x: local.dx, y: local.dy),
      (left: 0, top: 0, width: s, height: s),
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
        ink: Color(0xff000000 | spec.ink),
      ),
    );
    final label = widget.semanticLabel ?? spec.definition.name;
    child = label.isEmpty
        ? ExcludeSemantics(child: child)
        : Semantics(label: label, image: true, child: child);
    if (!widget.animate) return child;
    if (widget.followPointer) {
      child = MouseRegion(
        onHover: (e) => _look(e.localPosition),
        onExit: (_) => _target = null,
        child: child,
      );
    }
    if (widget.turnable) {
      child = GestureDetector(
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
    return child;
  }
}

/// Paints a [BotAvatarFrame] into its box: every cross-section in the body
/// colour, each eye in the ink, back to front. The 0..100 box fills the
/// canvas; a hop may draw a little past it, which is not clipped.
class BotAvatarPainter extends CustomPainter {
  BotAvatarPainter({
    required this.frame,
    required this.colour,
    required this.ink,
  }) : super(repaint: frame);

  final ValueNotifier<BotAvatarFrame> frame;
  final Color colour;
  final Color ink;

  /// Each cross-section's path, built the first time it is drawn: a slice
  /// belongs to a cached volume, so this lives as long as that does.
  static final _paths = Expando<ui.Path>("bot-avatar-slice");

  static ui.Path _pathOf(VolumeSlice slice) => _paths[slice] ??= () {
    final path = ui.Path()
      ..fillType = slice.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
    for (final loop in slice.loops) {
      path.addPolygon([for (final (x, y) in loop) Offset(x, y)], true);
    }
    return path;
  }();

  static Float64List _matrix(Affine m) => Float64List.fromList([
    m.a, m.b, 0, 0, //
    m.c, m.d, 0, 0, //
    0, 0, 1, 0, //
    m.e, m.f, 0, 1, //
  ]);

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame.value;
    final body = Paint()
      ..color = colour
      ..isAntiAlias = true;
    final eyes = Paint()..color = ink;
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
          canvas.drawPath(_pathOf(slice), body);
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
            eyes,
          );
        case EyeShapeMark(mark: final ArcMark arc):
          canvas.drawPath(
            ui.Path()
              ..moveTo(arc.x0, arc.y)
              ..quadraticBezierTo(arc.cx, arc.cy, arc.x1, arc.y),
            Paint()
              ..color = ink
              ..style = PaintingStyle.stroke
              ..strokeWidth = arc.strokeWidth
              ..strokeCap = StrokeCap.round,
          );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BotAvatarPainter old) =>
      old.frame != frame || old.colour != colour || old.ink != ink;
}
