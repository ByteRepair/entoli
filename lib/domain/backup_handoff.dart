import "dart:typed_data";

/// The backup on its way out of the app and back in. `FileHandoff` is the same
/// job for a workspace file and this is not one: a backup has no path in a
/// workspace to hand over, and Entoli composes it rather than finding it.
///
/// Not gated per platform the way that one is: every platform the app runs on
/// has somewhere to put a file and a chooser to get one back — a save dialog on
/// a desktop, a download in a browser, the share sheet on Android — so there is
/// no capability here for a page to draw around.
abstract interface class BackupHandoff {
  /// Hand [bytes] to the user as a file called [name].
  Future<void> save(String name, Uint8List bytes);

  /// The file the user picked, or null if they cancelled.
  Future<Uint8List?> pick();
}
