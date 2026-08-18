import "dart:typed_data";

import "package:file_selector/file_selector.dart";

import "../domain/backup_handoff.dart";

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
