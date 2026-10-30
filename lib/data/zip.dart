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
    await for (final entry in _entries(paths, base, skip, skipDir)) {
      entry.isDirectory
          ? encoder.addArchiveFile(ArchiveFile.directory(entry.name))
          : await encoder.addFile(File(entry.path), entry.name);
    }
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
  await for (final entry in _entries(paths, base, skip, skipDir)) {
    archive.add(entry.isDirectory
        ? ArchiveFile.directory(entry.name)
        : ArchiveFile.bytes(entry.name, await File(entry.path).readAsBytes()));
  }
  return archive;
}

/// What the archive is called: the folder that was picked, or the one
/// everything selected sits in.
String zipNameFor(List<String> paths) {
  final named = paths.length == 1 ? paths.single : p.dirname(paths.first);
  return "${p.basename(named)}.zip";
}

/// Every member [paths] make, in walk order: each folder before what is in
/// it, named relative to [base] or the path's own parent.
Stream<({String path, String name, bool isDirectory})> _entries(
  List<String> paths,
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
) async* {
  Stream<({String path, String name, bool isDirectory})> walk(
      String from, String path, bool isDirectory) async* {
    if (!isDirectory) {
      if (skip == null || !skip(path)) {
        yield (path: path, name: p.relative(path, from: from), isDirectory: false);
      }
      return;
    }
    if (skipDir != null && skipDir(path)) return;
    // Its own entry as well as its contents': an empty folder is otherwise
    // nothing at all, and a zip of one alone would come out empty. The base
    // itself is not one of its own entries — `.` names nothing to unzip.
    final name = p.relative(path, from: from);
    if (name != ".") yield (path: path, name: name, isDirectory: true);
    // On the entity rather than its path: `list` has already answered which
    // each one is, and asking again is a stat per file.
    await for (final entity in Directory(path).list()) {
      yield* walk(from, entity.path, entity is Directory);
    }
  }

  for (final path in paths) {
    yield* walk(base ?? p.dirname(path), path,
        FileSystemEntity.isDirectorySync(path));
  }
}
