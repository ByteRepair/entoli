import "package:flutter/widgets.dart";

/// A camera view that reads QR codes, for a pairing code shown on another
/// screen.
abstract interface class CodeScanner {
  /// A live camera view calling [onCode] with the text of each code it reads,
  /// until [onCode] returns true, which stops the camera. [refused] stands in
  /// for the view where the camera permission was refused, [failed] with the
  /// reason where the camera would not start for any other.
  Widget view({
    required bool Function(String code) onCode,
    required WidgetBuilder refused,
    required Widget Function(BuildContext context, String reason) failed,
  });
}
