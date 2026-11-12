import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter_math_fork/flutter_math.dart";

import "../app/transcript/formula.dart";

/// Typesets TeX with `flutter_math_fork` — KaTeX's layout in pure Dart —
/// into a picture, off screen: a render tree of its own, laid out and
/// painted once and read back as PNG. Nothing of it is ever on a screen, so
/// a frontend that draws no Flutter can show maths all the same.
class MathPngRenderer implements FormulaRenderer {
  const MathPngRenderer();

  /// Wider than any formula, so one is laid out at its own width.
  static const _room = Size(8192, 4096);

  @override
  Future<FormulaImage> render(String tex, FormulaStyle style) async {
    String? error;
    final probe = _BaselineProbe();
    final boundary = RenderRepaintBoundary();
    final view = RenderView(
      view: ui.PlatformDispatcher.instance.implicitView!,
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(_room),
        devicePixelRatio: style.scale,
      ),
      child: RenderPositionedBox(alignment: Alignment.topLeft, child: boundary),
    );
    final pipeline = PipelineOwner()..rootNode = view;
    view.prepareInitialFrame();
    final build = BuildOwner(focusManager: FocusManager());
    final colour = Color(style.argb);
    final textStyle = TextStyle(fontSize: style.fontSize, color: colour);
    final root = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: _Baseline(
          probe: probe,
          child: Math.tex(
            tex,
            mathStyle: style.display ? MathStyle.display : MathStyle.text,
            textStyle: textStyle,
            onErrorFallback: (e) {
              error = e.message;
              return Text(tex, style: textStyle);
            },
          ),
        ),
      ),
    ).attachToRenderTree(build);
    try {
      build
        ..buildScope(root)
        ..finalizeTree();
      pipeline
        ..flushLayout()
        ..flushCompositingBits()
        ..flushPaint();
      final size = boundary.size;
      final baseline = probe.baseline ?? size.height;
      final image = await boundary.toImage(pixelRatio: style.scale);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        return FormulaImage(
          png: bytes!.buffer.asUint8List(),
          width: size.width,
          height: size.height,
          baseline: baseline,
          error: error,
        );
      } finally {
        image.dispose();
      }
    } finally {
      // Unmounts the tree, so nothing it built outlives the picture.
      RenderObjectToWidgetAdapter<RenderBox>(
        container: boundary,
      ).attachToRenderTree(build, root);
      build.finalizeTree();
      view.dispose();
    }
  }
}

/// Hands the render tree [probe] as the formula's parent.
class _Baseline extends SingleChildRenderObjectWidget {
  const _Baseline({required this.probe, super.child});

  final _BaselineProbe probe;

  @override
  RenderObject createRenderObject(BuildContext context) => probe;
}

/// Reads the formula's baseline while laying it out, the one time a box may
/// ask its child for one.
class _BaselineProbe extends RenderProxyBox {
  double? baseline;

  @override
  void performLayout() {
    super.performLayout();
    baseline = child?.getDistanceToBaseline(TextBaseline.alphabetic);
  }
}
