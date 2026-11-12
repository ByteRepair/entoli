import "dart:typed_data";

import "package:flutter/foundation.dart" show SynchronousFuture;
import "package:flutter_riverpod/flutter_riverpod.dart";

/// How a formula is to be typeset: inline in a sentence or on a line of its
/// own, at a text size, in a colour, for a screen of [scale] pixels a point.
class FormulaStyle {
  const FormulaStyle({
    required this.display,
    required this.fontSize,
    required this.argb,
    this.scale = 2,
  });

  final bool display;
  final double fontSize;
  final int argb;
  final double scale;

  @override
  bool operator ==(Object other) =>
      other is FormulaStyle &&
      other.display == display &&
      other.fontSize == fontSize &&
      other.argb == argb &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(display, fontSize, argb, scale);
}

/// A typeset formula: PNG bytes at the style's scale, its size in points,
/// and how far below its top the baseline is, which is what sets an inline
/// one in its sentence. [error] is what the TeX could not be read as, the
/// picture then being the TeX itself drawn plainly.
class FormulaImage {
  const FormulaImage({
    required this.png,
    required this.width,
    required this.height,
    required this.baseline,
    this.error,
  });

  final Uint8List png;
  final double width;
  final double height;
  final double baseline;
  final String? error;
}

/// Turns TeX into a picture. The one place the app typesets maths: the
/// native frontend draws these pictures, and a copy pastes them where a
/// target keeps formatting. Bound at the root (`main`), since typesetting
/// is drawing and the core draws nothing.
abstract interface class FormulaRenderer {
  Future<FormulaImage> render(String tex, FormulaStyle style);
}

/// A [FormulaRenderer] that typesets each TeX and style once: a reply is
/// redrawn on every streamed delta, and the same formula is asked for again
/// each time. Bounded, the oldest going first; a request already in flight
/// is shared rather than started twice.
class CachedFormulaRenderer implements FormulaRenderer {
  CachedFormulaRenderer(this._inner, {this.limit = 256});

  final FormulaRenderer _inner;
  final int limit;

  final _done = <(String, FormulaStyle), FormulaImage>{};
  final _pending = <(String, FormulaStyle), Future<FormulaImage>>{};

  /// What is already typeset, without waiting: a frontend drawing a reply
  /// takes what is ready and asks for the rest.
  FormulaImage? ready(String tex, FormulaStyle style) {
    final key = (tex, style);
    final hit = _done.remove(key);
    if (hit != null) _done[key] = hit;
    return hit;
  }

  @override
  Future<FormulaImage> render(String tex, FormulaStyle style) {
    final hit = ready(tex, style);
    if (hit != null) return SynchronousFuture(hit);
    final key = (tex, style);
    return _pending[key] ??= _inner
        .render(tex, style)
        .then(
          (image) {
            _pending.remove(key);
            _done[key] = image;
            while (_done.length > limit) {
              _done.remove(_done.keys.first);
            }
            return image;
          },
          onError: (Object e) {
            _pending.remove(key);
            throw e;
          },
        );
  }
}

/// The app's formula renderer, cached; `main` binds the typesetter.
final formulaRendererProvider = Provider<CachedFormulaRenderer>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);
