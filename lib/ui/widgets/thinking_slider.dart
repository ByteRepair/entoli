import "dart:math" as math;

import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";
import "package:flutter/services.dart";

import "../../core/noise.dart";

/// A choice of how hard something thinks, as a bar of points: the left is the
/// least thought and the right the most. The bar is a field of dots drawn from
/// [ValueNoise], sparse and slow on the left and dense with detail on the
/// right, lit up to the point picked. It moves while the pointer is over it and
/// for a moment after a pick, and is still otherwise, so it costs nothing at
/// rest.
///
/// [stops] are the points left to right, each with the label shown under it;
/// what they mean is the caller's. [help] is the line under the labels.
class ThinkingSlider<T> extends StatefulWidget {
  const ThinkingSlider({
    super.key,
    required this.stops,
    required this.value,
    required this.onChanged,
    this.help,
  }) : assert(stops.length > 1);

  final Map<T, String> stops;
  final T value;
  final ValueChanged<T> onChanged;
  final String? help;

  @override
  State<ThinkingSlider<T>> createState() => _ThinkingSliderState<T>();
}

class _ThinkingSliderState<T> extends State<ThinkingSlider<T>>
    with SingleTickerProviderStateMixin {
  /// Seconds of motion so far: what the pattern is drawn at.
  final _phase = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_tick);
  var _last = Duration.zero;
  var _until = Duration.zero;
  var _hovered = false;

  late var _keys = widget.stops.keys.toList();
  int get _index => math.max(0, _keys.indexOf(widget.value));

  @override
  void didUpdateWidget(ThinkingSlider<T> old) {
    super.didUpdateWidget(old);
    _keys = widget.stops.keys.toList();
    if (old.value != widget.value) _think();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _phase.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    _phase.value += (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (!_hovered && elapsed >= _until) _ticker.stop();
  }

  /// Moves the pattern for [time] more, or for as long as it is hovered.
  void _think([Duration time = const Duration(milliseconds: 1600)]) {
    if (MediaQuery.disableAnimationsOf(context)) return;
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
    _until = _last + time;
  }

  void _hover(bool on) {
    _hovered = on;
    if (on) _think();
  }

  void _pick(int index) {
    final key = _keys[index.clamp(0, _keys.length - 1)];
    if (key != widget.value) widget.onChanged(key);
  }

  void _pickAt(double x, double width) =>
      _pick((x / width * _keys.length).floor());

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.arrowDown => -1,
      LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.arrowUp => 1,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.ignored;
    _pick(_index + step);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labels = widget.stops.values.toList();
    final index = _index;
    return Semantics(
      slider: true,
      value: labels[index],
      // Each end offers only the way it can still go.
      increasedValue: index + 1 < labels.length ? labels[index + 1] : null,
      decreasedValue: index > 0 ? labels[index - 1] : null,
      onIncrease: index + 1 < labels.length ? () => _pick(index + 1) : null,
      onDecrease: index > 0 ? () => _pick(index - 1) : null,
      child: Focus(
        onKeyEvent: _key,
        // The labels sit under their points, so a tap on one picks it too.
        child: LayoutBuilder(
          builder: (context, constraints) => MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => _hover(true),
            onExit: (_) => _hover(false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) =>
                  _pickAt(d.localPosition.dx, constraints.maxWidth),
              onHorizontalDragUpdate: (d) =>
                  _pickAt(d.localPosition.dx, constraints.maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Repainted every frame while it moves, without the text
                  // around it.
                  RepaintBoundary(
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, 44),
                      painter: _ThoughtPainter(
                        phase: _phase,
                        count: labels.length,
                        index: index,
                        scheme: scheme,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      for (final (i, label) in labels.indexed)
                        Expanded(
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: i == index
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                              fontWeight: i == index ? FontWeight.w600 : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (widget.help case final help?) ...[
                    const SizedBox(height: 8),
                    Text(help, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar: a halftone of filaments — the ridges of a noise field warped by
/// itself — whose frequency and layers of detail grow from left to right, and
/// the points over it.
class _ThoughtPainter extends CustomPainter {
  _ThoughtPainter({
    required this.phase,
    required this.count,
    required this.index,
    required this.scheme,
  }) : super(repaint: phase);

  final ValueNotifier<double> phase;
  final int count;
  final int index;
  final ColorScheme scheme;

  static final _noise = ValueNoise(7);
  static const _cell = 3.5;

  /// A dot's colour by how much of a line it is, in 256 steps, lit and not:
  /// built once per painter rather than twice per dot per frame.
  late final _lit = _ramp(0.25, 0.75);
  late final _dim = _ramp(0.1, 0.25);

  List<Color> _ramp(double alpha, double gain) => [
    for (var i = 0; i < 256; i++)
      Color.lerp(
        scheme.outlineVariant,
        scheme.primary,
        i / 255,
      )!.withValues(alpha: alpha + gain * i / 255),
  ];

  double _pointX(int i, double width) => (i + 0.5) / count * width;

  @override
  void paint(Canvas canvas, Size size) {
    final bar = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(10),
    );
    canvas
      ..save()
      ..clipRRect(bar)
      ..drawRRect(bar, Paint()..color = scheme.surfaceContainerHighest);

    final t = phase.value;
    final litTo = _pointX(index, size.width) + _cell;
    final dot = Paint();
    for (var x = _cell / 2; x < size.width; x += _cell) {
      final u = x / size.width;
      // Less detailed on the left, more on the right: more layers of noise,
      // and more contour lines through it.
      final octaves = 1 + u * 4;
      final lines = 2 + u * 10;
      final colours = x <= litTo ? _lit : _dim;
      for (var y = _cell / 2; y < size.height; y += _cell) {
        final (nx, ny) = (x / size.height * 0.45, y / size.height * 0.45);
        // The field warped by itself, so the lines curl like smoke.
        final warp = _noise.fractal(
          nx * 0.6 + t * 0.12,
          ny * 0.6 - t * 0.08,
          2,
        );
        final n = _noise.fractal(
          nx + warp * 1.8,
          ny + warp * 1.2 + t * 0.2,
          octaves,
        );
        final wave = 0.5 + 0.5 * math.cos(2 * math.pi * n * lines);
        final squared = wave * wave;
        final line = squared * squared * squared;
        dot.color = colours[(line * 255).round()];
        canvas.drawCircle(Offset(x, y), _cell / 2 * (0.35 + 0.65 * line), dot);
      }
    }
    canvas.restore();

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var i = 0; i < count; i++) {
      final c = Offset(_pointX(i, size.width), size.height / 2);
      if (i == index) {
        canvas
          ..drawCircle(c, 9, Paint()..color = scheme.primary)
          ..drawCircle(c, 3.5, Paint()..color = scheme.onPrimary);
      } else {
        canvas
          ..drawCircle(c, 5, Paint()..color = scheme.surface)
          ..drawCircle(
            c,
            5,
            ring..color = i < index ? scheme.primary : scheme.outline,
          );
      }
    }
  }

  @override
  bool shouldRepaint(_ThoughtPainter old) =>
      old.count != count || old.index != index || old.scheme != scheme;
}
