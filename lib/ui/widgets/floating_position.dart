import "package:flutter/rendering.dart";
import "package:flutter/scheduler.dart";
import "package:flutter/widgets.dart";

/// A child of a [Wrap] whose painted position glides to wherever the wrap
/// next puts it, instead of snapping there.
///
/// The wrap lays this out as an ordinary child and moves it by rewriting
/// [WrapParentData.offset] — after [RenderBox.layout] has returned, and
/// without asking the child to repaint, so nothing in a box tree can
/// interpolate that jump and nothing would even see it. [RenderFloatingPosition]
/// does both: it paints its child at the offset the paint is catching up to,
/// and it asks for that paint after every layout, where the wrap has already
/// written the new slot. It retargets mid-flight from where the child
/// visually is, which is what makes a chip pushed onto a new line by its
/// neighbours appear to travel there rather than teleport.
///
/// The glide follows one fixed deadline per run — each frame closes the same
/// eased share of whatever gap remains — so a target that keeps moving while
/// a neighbour's size animates is chased smoothly and landed on exactly when
/// the run ends, rather than crawled after. Hit-testing and paint transforms
/// follow the painted offset, so a tap or a tooltip anchor lands where the
/// child is shown, not where it is laid out.
class FloatingPosition extends SingleChildRenderObjectWidget {
  const FloatingPosition({
    super.key,
    required super.child,
    this.duration = const Duration(milliseconds: 180),
    this.curve = Curves.easeOut,
  });

  /// How long a glide takes.
  final Duration duration;

  /// The easing a glide follows.
  final Curve curve;

  @override
  RenderFloatingPosition createRenderObject(BuildContext context) {
    return RenderFloatingPosition(duration: duration, curve: curve);
  }
}

class RenderFloatingPosition extends RenderProxyBox {
  RenderFloatingPosition({
    this.duration = const Duration(milliseconds: 180),
    this.curve = Curves.easeOut,
  }) {
    _ticker = Ticker(_onFrame);
  }

  late final Ticker _ticker;

  /// How long a glide takes, and the easing it follows.
  final Duration duration;
  final Curve curve;

  /// Where the child is painted, against the slot the wrap gave it.
  Offset? _painted;

  /// What the current run is catching up to.
  Offset? _target;

  /// The eased progress already spent of the current run.
  double _eased = 0;

  /// The settled offset the parent laid out, which is what the wrap would
  /// paint at without this render object.
  Offset get _settled {
    final data = parentData;
    return data is WrapParentData ? data.offset : Offset.zero;
  }

  /// Where the child is being painted this frame, for tests to assert on.
  Offset get paintedOffset => _painted ?? _settled;

  /// The painted offset minus the settled one: where the child is shown
  /// relative to where the wrap laid it. Zero before the first paint, when
  /// there is no shown position yet.
  Offset get _delta {
    final painted = _painted;
    return painted == null ? Offset.zero : painted - _settled;
  }

  void _onFrame(Duration elapsed) {
    final progress =
        (elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
    final eased = curve.transform(progress);
    // Each frame closes the same eased share of the gap that remains, so a
    // target that moves mid-run is chased without the run resetting, and the
    // share reaches exactly 1 — the child lands on the target at the
    // deadline rather than creeping toward it forever.
    final share = (eased - _eased) / (1.0 - _eased);
    _eased = eased;
    _painted = Offset.lerp(_painted, _target, share);
    // A target that moved back onto the painted position has nothing left to
    // close; ticking to the deadline would repaint the subtree for nothing.
    if (progress >= 1.0 || _painted == _target) {
      _painted = _target;
      _ticker.stop();
    }
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final settled = _settled;
    if (_painted == null) {
      // First paint: appear where the wrap put this, with nothing to glide
      // from.
      _painted = settled;
    } else if (settled != _target) {
      _target = settled;
      // A run only closes a gap. A slot that moved back to where the child
      // is already painted updates the target without one; a run already in
      // flight keeps chasing whatever target it is given.
      if (_painted != settled && !_ticker.isActive) {
        _eased = 0;
        _ticker.start();
      }
    }
    final delta = _delta;
    if (delta == Offset.zero) {
      context.paintChild(child!, offset);
    } else {
      context.paintChild(child!, offset + delta);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final delta = _delta;
    return result.addWithPaintOffset(
      offset: delta == Offset.zero ? null : delta,
      position: position,
      hitTest: (result, transformed) =>
          child!.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    super.applyPaintTransform(child, transform);
    final delta = _delta;
    if (delta != Offset.zero) {
      transform.translateByDouble(delta.dx, delta.dy, 0, 1);
    }
  }

  @override
  void detach() {
    if (_ticker.isActive) {
      _ticker.stop();
    }
    super.detach();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}