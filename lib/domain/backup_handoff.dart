import "dart:typed_data";

/// The backup on its way out of the app and back in. `FileHandoff` is the same
/// job for a workspace file and this is not one — see CLAUDE.md, "Backing it
/// all up". Ungated, unlike that port: every platform has somewhere to put a
/// file and a chooser to get one back — which is also why a skill or agent
/// exported from the settings pages rides it, a `.skill` zip or an `.md`
/// beside the backup the same routes carry out.
abstract interface class BackupHandoff {
  /// Hand [bytes] to the user as a file called [name].
  Future<void> save(String name, Uint8List bytes);

  /// The file the user picked, or null if they cancelled.
  Future<Uint8List?> pick();
}
