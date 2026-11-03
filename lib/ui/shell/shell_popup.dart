import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/widgets.dart";

import "../../core/log.dart";

/// A strip of choices drawn by the native shell over the Flutter view, in the
/// system's glass, just above [anchor] — the rect of what opened it, in the
/// Flutter view's own coordinates. Each choice is its glyph and its name;
/// [chosen] are drawn picked. Answers the index picked, or null for a strip
/// dismissed.
Future<int?> showShellStrip({
  required Rect anchor,
  required List<({String glyph, String name})> choices,
  Set<int> chosen = const {},
}) async {
  try {
    return await NativeShell().strip(
      ChoiceStrip(
        x: anchor.left,
        y: anchor.top,
        width: anchor.width,
        height: anchor.height,
        options: [
          for (final (i, c) in choices.indexed)
            StripOption(
              glyph: c.glyph,
              name: c.name,
              chosen: chosen.contains(i),
            ),
        ],
      ),
    );
  } catch (e) {
    logFailure("shell", "strip: $e");
    return null;
  }
}

/// [context]'s widget as a rect in the Flutter view, for [showShellStrip].
Rect? anchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
