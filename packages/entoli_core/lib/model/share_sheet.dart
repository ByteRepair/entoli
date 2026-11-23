import "dart:ui" show Rect;

/// The platform's share sheet, for a link the user sends on themselves.
abstract interface class ShareSheet {
  /// Offers [link] to the apps the platform has, the sheet pointing from
  /// [origin] where it needs one (an iPad's popover). False where the
  /// platform has no sheet worth handing it to, which the caller answers
  /// another way; throws where the sheet did not open.
  Future<bool> shareLink(Uri link, {Rect? origin});
}
