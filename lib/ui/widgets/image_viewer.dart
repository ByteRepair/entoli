import "dart:typed_data";
import "dart:ui" show ImageFilter;

import "package:flutter/material.dart";

/// [bytes] filling the screen less a margin, over a blur of whatever was
/// behind it. A tap anywhere, the back button or Escape closes it.
Future<void> showImageViewer(BuildContext context, Uint8List bytes, {String? label}) =>
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black26,
      pageBuilder: (context, _, _) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Image.memory(bytes, fit: BoxFit.contain, semanticLabel: label),
            ),
          ),
        ),
      ),
    );
