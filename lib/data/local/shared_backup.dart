import "../../domain/file_handoff.dart";
import "../backup_handoff.dart";

/// Android, where `file_selector` implements no save dialog: a backup leaves
/// the way a workspace file does, through the share sheet. Coming back in is
/// the same chooser as everywhere else, which that half of the plugin does have
/// — hence extending rather than implementing.
class SharedBackup extends FileSelectorBackup {
  SharedBackup(this._handoff);

  final FileHandoff _handoff;

  @override
  Future<void> save(String path) => _handoff.export([path]);
}
