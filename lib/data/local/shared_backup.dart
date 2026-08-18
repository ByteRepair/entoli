import "dart:typed_data";

import "package:fs_shim/fs.dart";
import "package:path_provider/path_provider.dart";

import "../../domain/file_handoff.dart";
import "../backup_handoff.dart";

/// Android, where `file_selector` implements no save dialog: a backup leaves
/// the way a workspace file does, through the share sheet. Coming back in is
/// the same chooser as everywhere else, which that half of the plugin does have
/// — hence extending rather than implementing.
///
/// An intent carries a file rather than bytes, so the zip is written to the
/// cache and shared from there. [_handoff] then stages a copy of its own, since
/// a `FileProvider` only mints URIs under the paths it is configured with: the
/// archive is written twice, which is what it costs to reuse the route out
/// rather than open a second one.
class SharedBackup extends FileSelectorBackup {
  SharedBackup(this._fs, this._handoff);

  final FileSystem _fs;
  final FileHandoff _handoff;

  /// Asked once, the way `AndroidFileHandoff` asks: `path_provider` sends a
  /// platform message per call.
  late final Future<String> _cache =
      getTemporaryDirectory().then((dir) => dir.path);

  @override
  Future<void> save(String name, Uint8List bytes) async {
    final file = _fs.file(_fs.path.join(await _cache, name));
    await file.writeAsBytes(bytes);
    try {
      await _handoff.export([file.path]);
    } finally {
      // The sheet was handed the staged copy, not this one.
      await file.delete();
    }
  }
}
