import "package:fs_shim/fs.dart";

import "file_handoff.dart";

/// Reading and writing a workspace folder, for the explorer and for whatever a
/// share drops into one. Everything here goes through a `FileSystem`, so it is
/// the same code over a disk and over IndexedDB.

/// One entry of a workspace folder, as the explorer draws it.
class WorkspaceEntry {
  const WorkspaceEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
  });

  final String path;
  final String name;
  final bool isDirectory;

  /// Bytes, and zero for a folder — a directory's own size says nothing about
  /// what is in it.
  final int size;
}

/// What is in [dir]: folders first, then files, each by name. A folder that is
/// not there yet is empty rather than an error — a workspace is created with
/// the chat and may never be written to.
///
/// The listing is drained before anything is stat-ed, and the stats then go out
/// together: awaiting one inside the loop pauses the stream on each, which on
/// the web is one IndexedDB transaction per file, serialised, in front of the
/// spinner.
Future<List<WorkspaceEntry>> listWorkspace(FileSystem fs, String dir) async {
  final directory = fs.directory(dir);
  if (!await directory.exists()) return const [];
  final entities = await directory.list().toList();
  final entries = await Future.wait(entities.map((entity) async {
    final isDirectory = entity is Directory;
    return WorkspaceEntry(
      path: entity.path,
      name: fs.path.basename(entity.path),
      isDirectory: isDirectory,
      size: isDirectory ? 0 : (await entity.stat()).size,
    );
  }));
  return entries
    ..sort((a, b) => a.isDirectory == b.isDirectory
        ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
        : (a.isDirectory ? -1 : 1));
}

/// Write [files] into [dir], creating whatever folders they name. Their paths
/// were written by another app, so each one is sanitised before it is joined
/// onto a workspace — see [safeRelativePath].
///
/// One at a time, and each one's bytes are the file's own business: this makes
/// room and hands over the target, so a staged share is moved where a browser's
/// buffer is written. See [IncomingFile].
///
/// Sequential on purpose. Writing them at once would put every file's bytes in
/// memory together, which is the thing [IncomingFile] exists to avoid, and buys
/// nothing back — IndexedDB serialises writes to a store anyway, and a rename
/// is too cheap to overlap.
///
/// The folders are made first, once each. A folder upload names one directory
/// hundreds of times, and `create` on the web opens a read-write transaction
/// before it looks, so asking per file is hundreds of empty transactions in
/// front of the spinner.
Future<void> writeIncoming(
  FileSystem fs,
  String dir,
  List<IncomingFile> files,
) async {
  final targets = [
    for (final file in files) fs.path.join(dir, safeRelativePath(fs, file.path)),
  ];
  for (final folder in {for (final target in targets) fs.path.dirname(target)}) {
    await fs.directory(folder).create(recursive: true);
  }
  for (var i = 0; i < files.length; i++) {
    await files[i].writeTo(fs, targets[i]);
  }
}

/// A path from outside, made safe to join onto a workspace. `..` and a leading
/// separator are what this exists for: a shared file names itself, and one
/// naming `../../settings.json` would otherwise be written there. Everything
/// left is kept, so a folder upload keeps its shape.
String safeRelativePath(FileSystem fs, String path) {
  final segments = path
      .split(RegExp(r"[/\\]"))
      .where((s) => s.isNotEmpty && s != "." && s != "..")
      .map(_safeSegment)
      .toList();
  return segments.isEmpty ? "file" : segments.join(fs.path.separator);
}

/// A drive letter or a colon is a path on Windows and a filename everywhere
/// else, so it goes with the rest of what a filesystem will not take.
String _safeSegment(String segment) {
  final safe = segment.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), "_").trim();
  return safe.isEmpty ? "file" : safe;
}
