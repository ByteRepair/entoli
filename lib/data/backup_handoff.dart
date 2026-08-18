import "dart:typed_data";

import "package:file_selector/file_selector.dart";
import "package:fs_shim/fs.dart";

import "../domain/backup_handoff.dart";
import "../domain/file_handoff.dart";

const _backups = XTypeGroup(
  label: "Entoli backup",
  extensions: ["zip"],
  mimeTypes: ["application/zip"],
  uniformTypeIdentifiers: ["public.zip-archive"],
  webWildCards: ["application/zip"],
);

/// A save dialog and a file chooser, through `file_selector` — one plugin over
/// the desktops and a browser. The browser has no dialog to show and answers
/// with a download instead, which is the same promise from where the user is
/// standing.
class FileSelectorBackup implements BackupHandoff {
  const FileSelectorBackup();

  @override
  Future<void> save(String name, Uint8List bytes) async {
    final location =
        await getSaveLocation(suggestedName: name, acceptedTypeGroups: const [_backups]);
    if (location == null) return;
    await XFile.fromData(bytes, name: name, mimeType: "application/zip")
        .saveTo(location.path);
  }

  @override
  Future<Uint8List?> pick() async {
    final file = await openFile(acceptedTypeGroups: const [_backups]);
    return file?.readAsBytes();
  }
}

/// Android, where `file_selector` implements no save dialog: a backup leaves
/// the way a workspace file does, through the share sheet. Coming back in is
/// the same chooser as everywhere else, which that half of the plugin does
/// have.
///
/// The share sheet is handed a path rather than bytes, so the backup is written
/// to [tempDir] and shared from there. [handoff] stages its own copy under the
/// app's cache — the only place a `FileProvider` will mint a URI from — so this
/// one is finished with the moment the sheet has been opened.
class SharedBackup extends FileSelectorBackup {
  const SharedBackup(this._fs, this._handoff, this.tempDir);

  final FileSystem _fs;
  final FileHandoff _handoff;

  /// Where a file the app is only passing through goes. Injected rather than
  /// asked for here: it is `path_provider`'s answer, and this file compiles on
  /// a platform that has no plugins at all.
  final Future<String> Function() tempDir;

  @override
  Future<void> save(String name, Uint8List bytes) async {
    final path = _fs.path.join(await tempDir(), name);
    final file = _fs.file(path);
    await file.writeAsBytes(bytes);
    try {
      await _handoff.export([path]);
    } finally {
      await file.delete();
    }
  }
}
