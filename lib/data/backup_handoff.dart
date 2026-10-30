import "package:file_selector/file_selector.dart";

import "../domain/backup_handoff.dart";

const _backups = XTypeGroup(
  label: "Entoli backup",
  extensions: ["zip"],
  mimeTypes: ["application/zip"],
  uniformTypeIdentifiers: ["public.zip-archive"],
);

/// A save dialog and a file chooser, through `file_selector`.
class FileSelectorBackup implements BackupHandoff {
  const FileSelectorBackup();

  @override
  Future<bool> save(String name, Future<void> Function(String path) write) async {
    final location =
        await getSaveLocation(suggestedName: name, acceptedTypeGroups: const [_backups]);
    if (location == null) return false;
    await write(location.path);
    return true;
  }

  @override
  Future<String?> pick() async =>
      (await openFile(acceptedTypeGroups: const [_backups]))?.path;
}
