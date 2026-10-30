/// The backup on its way out of the app and back in. `FileHandoff` is the same
/// job for a workspace file and this is not one — see AGENTS.md, "Backing it
/// all up". Ungated, unlike that port: every platform has somewhere to put a
/// file and a chooser to get one back — which is also why a skill or agent
/// exported from the settings pages rides it, a `.skill` zip or an `.md`
/// beside the backup the same routes carry out.
///
/// Files rather than bytes both ways, so a backup the size of the data
/// directory never has to fit in memory to leave or to come back.
abstract interface class BackupHandoff {
  /// Hand the user a file called [name], which [write] makes at the path it is
  /// given — where the user chose, on a platform with a save dialog, so
  /// nothing is written twice and nothing at all on a cancel. False is a
  /// cancel.
  Future<bool> save(String name, Future<void> Function(String path) write);

  /// Where the file the user picked is, or null if they cancelled.
  Future<String?> pick();
}
