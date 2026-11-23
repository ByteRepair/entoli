import "package:flutter/material.dart";

import "nav_drawer.dart" show compactWidth;

/// A palette's frame: the whole screen on a phone, a box in the middle of
/// anything wider. [builder] is told which, for a back button the box has
/// no use for.
Future<T?> showPaletteDialog<T>(
  BuildContext context,
  Widget Function(bool compact) builder,
) {
  final compact = MediaQuery.sizeOf(context).width < compactWidth;
  return showDialog<T>(
    context: context,
    builder: (_) => compact
        ? Dialog.fullscreen(child: builder(true))
        : Dialog(
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
              child: builder(false),
            ),
          ),
  );
}
