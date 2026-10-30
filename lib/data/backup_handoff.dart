import "dart:io";

import "package:file_selector/file_selector.dart";
import "package:path/path.dart" as p;

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
  Future<void> save(String path) async {
    final location = await getSaveLocation(
        suggestedName: p.basename(path), acceptedTypeGroups: const [_backups]);
    if (location == null) return;
    await File(path).copy(location.path);
  }

  @override
  Future<String?> pick() async =>
      (await openFile(acceptedTypeGroups: const [_backups]))?.path;
}

/// Runs [use] over a path called [name] in a fresh temporary directory, for a
/// file on its way to [BackupHandoff.save], and removes the directory after.
Future<T> withStagedFile<T>(
    String name, Future<T> Function(String path) use) async {
  final dir = await Directory.systemTemp.createTemp("entoli-out");
  try {
    return await use(p.join(dir.path, name));
  } finally {
    await dir.delete(recursive: true);
  }
}
