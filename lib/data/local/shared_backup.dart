import "dart:io";

import "package:path/path.dart" as p;

import "../../domain/file_handoff.dart";
import "../backup_handoff.dart";

/// Android, where `file_selector` implements no save dialog: a backup leaves
/// the way a workspace file does, through the share sheet. Coming back in is
/// the same chooser as everywhere else, which that half of the plugin does have
/// — hence extending rather than implementing.
///
/// An intent carries a file, so the file is made in a temporary directory and
/// shared from there; [_handoff] stages a copy of its own, since a
/// `FileProvider` only mints URIs under the paths it is configured with.
class SharedBackup extends FileSelectorBackup {
  SharedBackup(this._handoff);

  final FileHandoff _handoff;

  @override
  Future<bool> save(
    String name,
    Future<void> Function(String path) write,
  ) async {
    final dir = await Directory.systemTemp.createTemp("entoli-out");
    try {
      final path = p.join(dir.path, name);
      await write(path);
      await _handoff.export([path]);
      return true;
    } finally {
      await dir.delete(recursive: true);
    }
  }
}
