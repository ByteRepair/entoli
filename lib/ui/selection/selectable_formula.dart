import "dart:async";
import "dart:math" as math;
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/rendering.dart";
import "package:flutter/widgets.dart";

import "copied_document.dart";
import "png_density.dart";

/// A drawn formula as one thing to select: a drag that passes over it picks
/// it up whole and highlights it, and what it copies is the TeX it was
/// written as. Part of a formula is no TeX, and the glyphs are not text a
/// selection could take a range of — `flutter_math_fork` draws them itself.
///
/// It registers with the selection container above it like any paragraph's
/// fragment, so it takes its place in a drag's order and in Select All, and
/// the reader of a copy finds it by type (`RenderSelectableFormula`). It can
/// also draw itself again ([FormulaDrawing]), which is what a target that
/// keeps formatting pastes: the drawing is in a repaint boundary of its own,
/// so the picture is the formula without the highlight washed over it.
class SelectableFormula extends SingleChildRenderObjectWidget {
  SelectableFormula({
    super.key,
    required this.written,
    required this.ink,
    required Widget child,
  }) : super(child: RepaintBoundary(child: child));

  /// The TeX with its delimiters, as the reply has it.
  final String written;

  /// The colour the theme draws the formula in, which a copy draws black.
  final Color ink;

  @override
  RenderSelectableFormula createRenderObject(BuildContext context) =>
      RenderSelectableFormula(
        written: written,
        ink: ink,
        selectionColor: _colorOf(context),
        registrar: SelectionContainer.maybeOf(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSelectableFormula renderObject,
  ) => renderObject
    ..written = written
    ..ink = ink
    ..selectionColor = _colorOf(context)
    ..registrar = SelectionContainer.maybeOf(context);

  static Color _colorOf(BuildContext context) =>
      DefaultSelectionStyle.of(context).selectionColor ??
      const Color(0x00000000);
}

class RenderSelectableFormula extends RenderProxyBox
    with Selectable, SelectionRegistrant
    implements FormulaDrawing {
  RenderSelectableFormula({
    required this.written,
    required this.ink,
    required this._selectionColor,
    SelectionRegistrar? registrar,
  }) {
    this.registrar = registrar;
    _geometry.addListener(markNeedsPaint);
  }

  String written;
  Color ink;

  Color _selectionColor;
  set selectionColor(Color value) {
    if (value == _selectionColor) return;
    _selectionColor = value;
    markNeedsPaint();
  }

  static const _unselected = SelectionGeometry(
    status: SelectionStatus.none,
    hasContent: true,
  );
  final _geometry = ValueNotifier<SelectionGeometry>(_unselected);

  /// The two edges of the selection, where it reaches this formula, in its
  /// own coordinates.
  Offset? _start;
  Offset? _end;

  LayerLink? _startHandle;
  LayerLink? _endHandle;

  bool get isSelected => _geometry.value.status == SelectionStatus.uncollapsed;

  @override
  void addListener(VoidCallback listener) => _geometry.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _geometry.removeListener(listener);

  @override
  SelectionGeometry get value => _geometry.value;

  @override
  List<Rect> get boundingBoxes => [Offset.zero & size];

  @override
  int get contentLength => 1;

  @override
  SelectedContent? getSelectedContent() =>
      isSelected ? SelectedContent(plainText: written) : null;

  @override
  SelectedContentRange? getSelection() => isSelected
      ? const SelectedContentRange(startOffset: 0, endOffset: 1)
      : null;

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    var result = SelectionResult.none;
    switch (event) {
      case SelectionEdgeUpdateEvent(:final type, :final globalPosition):
        final point = globalToLocal(globalPosition);
        if (type == SelectionEventType.startEdgeUpdate) {
          _start = point;
        } else {
          _end = point;
        }
        result = SelectionUtils.getResultBasedOnRect(Offset.zero & size, point);
      case ClearSelectionEvent():
        _start = _end = null;
      case SelectAllSelectionEvent() ||
          SelectWordSelectionEvent() ||
          SelectParagraphSelectionEvent():
        _start = Offset.zero;
        _end = Offset.infinite;
      case GranularlyExtendSelectionEvent(:final forward, :final isEnd):
        result = _extend(forward: forward, isEnd: isEnd);
      case DirectionallyExtendSelectionEvent(:final direction, :final isEnd):
        final forward =
            direction == SelectionExtendDirection.forward ||
            direction == SelectionExtendDirection.nextLine;
        result = _extend(forward: forward, isEnd: isEnd);
      default:
        break;
    }
    _update();
    return result;
  }

  /// A keyboard extension moves an edge past the whole formula, there being
  /// nothing inside it to stop at.
  SelectionResult _extend({required bool forward, required bool isEnd}) {
    if (_start == null || _end == null) {
      _start = _end = forward ? Offset.zero : Offset.infinite;
    }
    final moved = forward ? Offset.infinite : Offset.zero;
    final stays = isEnd ? _end == moved : _start == moved;
    if (isEnd) {
      _end = moved;
    } else {
      _start = moved;
    }
    if (!stays) return SelectionResult.end;
    return forward ? SelectionResult.next : SelectionResult.previous;
  }

  /// Where [point] falls against the formula in reading order: above or
  /// left of its middle is before it, below or right of it after.
  double _order(Offset point) {
    if (point.dy < 0) return -1;
    if (point.dy > size.height) return 1;
    return point.dx - size.width / 2;
  }

  /// Selected when the edges fall on either side of its middle: a selection
  /// that covers most of a formula takes it, and one that stops short of
  /// half leaves it.
  void _update() {
    final start = _start, end = _end;
    if (start == null || end == null) {
      _geometry.value = _unselected;
      return;
    }
    final a = _order(start), b = _order(end);
    if (math.min(a, b) >= 0 || math.max(a, b) <= 0) {
      _geometry.value = _unselected;
      return;
    }
    final box = Offset.zero & size;
    final first = SelectionPoint(
      localPosition: box.bottomLeft,
      lineHeight: box.height,
      handleType: TextSelectionHandleType.left,
    );
    final last = SelectionPoint(
      localPosition: box.bottomRight,
      lineHeight: box.height,
      handleType: TextSelectionHandleType.right,
    );
    final reversed = a > b;
    _geometry.value = SelectionGeometry(
      status: SelectionStatus.uncollapsed,
      hasContent: true,
      startSelectionPoint: reversed ? last : first,
      endSelectionPoint: reversed ? first : last,
      selectionRects: [box],
    );
  }

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_startHandle == startHandle && _endHandle == endHandle) return;
    _startHandle = startHandle;
    _endHandle = endHandle;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!isSelected) return;
    // Over the glyphs rather than under them: the formula draws its own
    // background-less glyphs, and a translucent wash on top is what a
    // paragraph's highlight looks like beside it.
    context.canvas.drawRect(offset & size, Paint()..color = _selectionColor);
    final value = _geometry.value;
    for (final (link, point) in [
      (_startHandle, value.startSelectionPoint),
      (_endHandle, value.endSelectionPoint),
    ]) {
      if (link == null || point == null) continue;
      context.pushLayer(
        LeaderLayer(link: link, offset: offset + point.localPosition),
        (context, offset) {},
        Offset.zero,
      );
    }
  }

  /// Drawn at three times its size so it stays sharp in a document zoomed
  /// in, and in black where the theme drew it in [ink], since what it pastes
  /// into is a page. A colour the TeX asked for — `\color{red}` — is what
  /// was meant, and stays.
  @override
  Future<FormulaPicture?> picture() async {
    final drawn = child;
    if (!attached || drawn is! RenderRepaintBoundary || !drawn.hasSize) {
      return null;
    }
    final image = await drawn.toImage(pixelRatio: _ratio);
    try {
      final bytes = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (bytes == null) return null;
      final pixels = bytes.buffer.asUint8List();
      _blacken(pixels, ink);
      final black = await _imageOf(pixels, image.width, image.height);
      try {
        final png = await black.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) return null;
        return FormulaPicture(
          withDensity(png.buffer.asUint8List(), _ratio),
          width: drawn.size.width,
          height: drawn.size.height,
        );
      } finally {
        black.dispose();
      }
    } finally {
      image.dispose();
    }
  }

  static const _ratio = 3.0;

  /// Every pixel of [rgba] drawn in [ink] made black, its coverage kept. An
  /// edge's colour is only as exact as its coverage allows — a pixel a tenth
  /// covered carries a tenth of the precision — so a pixel is the ink's when
  /// it is within two steps of it once multiplied by its coverage.
  static void _blacken(Uint8List rgba, Color ink) {
    final r = (ink.r * 255).round();
    final g = (ink.g * 255).round();
    final b = (ink.b * 255).round();
    for (var i = 0; i < rgba.length; i += 4) {
      final alpha = rgba[i + 3];
      if (alpha == 0) continue;
      if ((rgba[i] - r).abs() * alpha <= 510 &&
          (rgba[i + 1] - g).abs() * alpha <= 510 &&
          (rgba[i + 2] - b).abs() * alpha <= 510) {
        rgba[i] = rgba[i + 1] = rgba[i + 2] = 0;
      }
    }
  }

  static Future<ui.Image> _imageOf(Uint8List rgba, int width, int height) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  @override
  void dispose() {
    _geometry.dispose();
    super.dispose();
  }
}

/// Every formula drawn under [root], each drawn again for a copy, by the TeX
/// it was written as; one that could not be drawn is left out.
Future<Map<String, FormulaPicture>> formulaPicturesUnder(
  RenderObject? root,
) async {
  final formulas = <String, RenderSelectableFormula>{};
  void visit(RenderObject node) {
    if (node is RenderSelectableFormula) {
      formulas.putIfAbsent(node.written, () => node);
    } else {
      node.visitChildren(visit);
    }
  }

  if (root != null) visit(root);
  final pictures = await Future.wait([
    for (final formula in formulas.values) formula.picture(),
  ]);
  return {
    for (final (i, written) in formulas.keys.indexed) written: ?pictures[i],
  };
}
