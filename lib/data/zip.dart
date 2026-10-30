import "dart:io";

import "package:archive/archive_io.dart";
import "package:path/path.dart" as p;

/// Zip [paths] — files and folders alike — into a new file at [to]. Each
/// member is read and compressed in turn, straight into the file, so a tree of
/// any size costs one member's memory rather than the whole archive's. Entries
/// are named relative to [base], defaulting to each path's own parent, so
/// unzipping a folder gives the folder back rather than its contents loose.
/// [skip] drops a file by its path, and is never asked about a directory;
/// [skipDir] drops a directory by its path, and is asked before recursing into
/// it. [extra] goes in last, for a member of the caller's own.
Future<void> zipTo(
  String to,
  List<String> paths, {
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
  List<ArchiveFile> extra = const [],
}) async {
  final encoder = ZipFileEncoder()..create(to);
  try {
    await _walk(paths, base, skip, skipDir,
        directory: (name) => encoder.addArchiveFile(ArchiveFile.directory(name)),
        file: (path, name) => encoder.addFile(File(path), name));
    extra.forEach(encoder.addArchiveFile);
  } finally {
    await encoder.close();
  }
}

/// The same walk as [zipTo], held in memory: for the small trees — a skill, an
/// artifact — whose zip goes out as bytes.
Future<Archive> archiveOf(
  List<String> paths, {
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
}) async {
  final archive = Archive();
  await _walk(paths, base, skip, skipDir,
      directory: (name) => archive.add(ArchiveFile.directory(name)),
      file: (path, name) async =>
          archive.add(ArchiveFile.bytes(name, await File(path).readAsBytes())));
  return archive;
}

/// What the archive is called: the folder that was picked, or the one
/// everything selected sits in.
String zipNameFor(List<String> paths) {
  final named = paths.length == 1 ? paths.single : p.dirname(paths.first);
  return "${p.basename(named)}.zip";
}

typedef _Directory = void Function(String name);
typedef _File = Future<void> Function(String path, String name);

Future<void> _walk(
  List<String> paths,
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir, {
  required _Directory directory,
  required _File file,
}) async {
  for (final path in paths) {
    final from = base ?? p.dirname(path);
    if (await FileSystemEntity.isDirectory(path)) {
      if (skipDir == null || !skipDir(path)) {
        await _walkDirectory(from, path, skip, skipDir, directory, file);
      }
    } else if (skip == null || !skip(path)) {
      await file(path, p.relative(path, from: from));
    }
  }
}

/// Recurses on the entity rather than its path: `list` has already answered
/// which each one is, and asking again is a stat per file.
Future<void> _walkDirectory(
  String base,
  String path,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
  _Directory directory,
  _File file,
) async {
  // Its own entry as well as its contents': an empty folder is otherwise
  // nothing at all, and a zip of one alone would come out empty. The base
  // itself is not one of its own entries — `.` names nothing to unzip.
  final name = p.relative(path, from: base);
  if (name != ".") directory(name);
  await for (final entity in Directory(path).list()) {
    if (entity is Directory) {
      if (skipDir == null || !skipDir(entity.path)) {
        await _walkDirectory(base, entity.path, skip, skipDir, directory, file);
      }
    } else if (skip == null || !skip(entity.path)) {
      await file(entity.path, p.relative(entity.path, from: base));
    }
  }
}
