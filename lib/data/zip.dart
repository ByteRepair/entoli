import "dart:typed_data";

import "package:archive/archive.dart";
import "package:fs_shim/fs.dart";

/// Zip [paths] — files and folders alike — reading through [fs]. Entries are
/// named relative to their own parent, so unzipping a folder gives the folder
/// back rather than its contents loose.
///
/// Over the `FileSystem` rather than `dart:io` so there is one of these, and
/// beside neither `local/` nor `web/` for the same reason: a browser downloads
/// a zip of files it only ever had in IndexedDB.
Future<Uint8List> zipEntries(FileSystem fs, List<String> paths) async {
  final archive = Archive();
  for (final path in paths) {
    final base = fs.path.dirname(path);
    if (await fs.isDirectory(path)) {
      await _addDirectory(fs, archive, base, path);
    } else {
      await _addFile(fs, archive, base, path);
    }
  }
  return ZipEncoder().encodeBytes(archive);
}

/// What the archive is called: the folder that was picked, or the one
/// everything selected sits in.
String zipNameFor(FileSystem fs, List<String> paths) {
  final named = paths.length == 1 ? paths.single : fs.path.dirname(paths.first);
  return "${fs.path.basename(named)}.zip";
}

/// Recurses on the entity rather than its path: `list` has already answered
/// which each one is, and asking again is a stat per file — a whole extra
/// IndexedDB transaction each, on the platform that can least afford it.
Future<void> _addDirectory(
  FileSystem fs,
  Archive archive,
  String base,
  String path,
) async {
  // Its own entry as well as its contents': an empty folder is otherwise
  // nothing at all, and a zip of one alone would come out empty.
  archive.add(ArchiveFile.directory(fs.path.relative(path, from: base)));
  await for (final entity in fs.directory(path).list()) {
    if (entity is Directory) {
      await _addDirectory(fs, archive, base, entity.path);
    } else {
      await _addFile(fs, archive, base, entity.path);
    }
  }
}

Future<void> _addFile(FileSystem fs, Archive archive, String base, String path) async =>
    archive.add(ArchiveFile.bytes(
      fs.path.relative(path, from: base),
      await fs.file(path).readAsBytes(),
    ));
