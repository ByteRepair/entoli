import "dart:io";
import "dart:typed_data";

import "package:archive/archive_io.dart";
import "package:path/path.dart" as p;

import "../core/log.dart";
import "../domain/workspace.dart" show safeRelativePath;

/// Zip [paths] — files and folders alike — into a new file at [to]. Each
/// member is read and compressed in turn, straight into the file, so a tree of
/// any size costs one member's memory rather than the whole archive's. Entries
/// are named relative to [base], defaulting to each path's own parent, so
/// unzipping a folder gives the folder back rather than its contents loose.
/// [skip] drops a file by its path, and is never asked about a directory;
/// [skipDir] drops a directory by its path, and is asked before recursing into
/// it. [extra] goes in last, for a member of the caller's own. [followLinks]
/// is [walkTree]'s.
Future<void> zipTo(
  String to,
  List<String> paths, {
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
  List<ArchiveFile> extra = const [],
  bool followLinks = true,
}) async {
  final encoder = ZipFileEncoder()..create(to);
  try {
    await for (final entry in walkTree(
      paths,
      base: base,
      skip: skip,
      skipDir: skipDir,
      followLinks: followLinks,
    )) {
      entry.isDirectory
          ? encoder.addArchiveFile(ArchiveFile.directory(entry.name))
          : await _addStreamed(encoder, entry.path, entry.name);
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
  bool followLinks = true,
}) async {
  final archive = Archive();
  await for (final entry in walkTree(
    paths,
    base: base,
    skip: skip,
    skipDir: skipDir,
    followLinks: followLinks,
  )) {
    archive.add(
      entry.isDirectory
          ? ArchiveFile.directory(entry.name)
          : ArchiveFile.bytes(entry.name, await File(entry.path).readAsBytes()),
    );
  }
  return archive;
}

/// [path] into [encoder] as [name], read as it is compressed. One stat of the
/// path for the time and the mode, where `ZipFileEncoder.addFile` takes two —
/// beside the length the open reads off the handle either way.
Future<void> _addStreamed(
  ZipFileEncoder encoder,
  String path,
  String name,
) async {
  final stat = File(path).statSync();
  final input = InputFileStream(path);
  try {
    encoder.addArchiveFile(
      ArchiveFile.stream(name, input)
        ..lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000
        ..mode = stat.mode,
    );
  } finally {
    await input.close();
  }
}

/// What the archive is called: the folder that was picked, or the one
/// everything selected sits in.
String zipNameFor(List<String> paths) {
  final named = paths.length == 1 ? paths.single : p.dirname(paths.first);
  return "${p.basename(named)}.zip";
}

/// One member [walkTree] makes: its [path] on disk, and its [name] in a zip.
typedef TreeEntry = ({String path, String name, bool isDirectory});

/// Every member [paths] make, in walk order: each folder before what is in
/// it, named relative to [base] or the path's own parent. A link is followed,
/// so a member is what the link points at; with [followLinks] false it is no
/// member at all, even as one of [paths], for a tree handed to someone else,
/// where what it points at
/// outside itself is not the tree's to give. A broken link is never a member,
/// and nor is a link to a folder the walk is already inside, which would
/// never end.
/// [skip] and [skipDir] are as [zipTo]'s.
Stream<TreeEntry> walkTree(
  List<String> paths, {
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
  bool followLinks = true,
}) async* {
  // The real paths of the folders the walk is inside, where it follows links:
  // only those, not every folder seen, since two links to one folder
  // elsewhere are two copies of it rather than a loop.
  final inside = <String>{};

  Stream<TreeEntry> walk(
    String from,
    String path,
    bool isDirectory,
    String? real,
  ) async* {
    if (!isDirectory) {
      if (skip == null || !skip(path)) {
        yield (path: path, name: _member(path, from), isDirectory: false);
      }
      return;
    }
    if (skipDir != null && skipDir(path)) return;
    if (real != null && !inside.add(real)) return;
    // Its own entry as well as its contents': an empty folder is otherwise
    // nothing at all, and a zip of one alone would come out empty. The base
    // itself is not one of its own entries — `.` names nothing to unzip.
    final name = _member(path, from);
    if (name != ".") yield (path: path, name: name, isDirectory: true);
    // Listed without following, so only a link costs a lookup of where it
    // lands: a folder that is not one is its parent's real path and its name.
    await for (final entity in Directory(path).list(followLinks: false)) {
      if (entity is! Link) {
        final isDir = entity is Directory;
        yield* walk(
          from,
          entity.path,
          isDir,
          isDir && real != null ? p.join(real, p.basename(entity.path)) : null,
        );
      } else if (followLinks) {
        switch (FileSystemEntity.typeSync(entity.path)) {
          case FileSystemEntityType.file:
            yield* walk(from, entity.path, false, null);
          case FileSystemEntityType.directory:
            final target = _realOf(entity.path);
            // [skipDir] matches by position, which a link's own path lacks: a
            // link to a skipped folder is asked about where it lands.
            if (target == null || (skipDir != null && skipDir(target))) {
              continue;
            }
            yield* walk(from, entity.path, true, target);
          default:
        }
      }
    }
    if (real != null) inside.remove(real);
  }

  for (final path in paths) {
    if (!followLinks && FileSystemEntity.isLinkSync(path)) continue;
    final isDirectory = FileSystemEntity.isDirectorySync(path);
    yield* walk(
      base ?? p.dirname(path),
      path,
      isDirectory,
      followLinks && isDirectory ? _realOf(path) : null,
    );
  }
}

/// [path] with its links resolved, or null where it went between being
/// listed and being asked.
String? _realOf(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException catch (e) {
    logFailure("files", "a link could not be resolved", e.osError);
    return null;
  }
}

/// [archive]'s files written out under [dir]. Each name goes through
/// [safeRelativePath] first, so `../x` lands inside [dir] rather than beside
/// it; [accept] drops a member by the path it would be written to.
Future<void> extractInto(
  Archive archive,
  String dir, {
  bool Function(String target)? accept,
}) async {
  for (final member in archive) {
    if (member.isDirectory) continue;
    final target = p.join(dir, safeRelativePath(member.name));
    if (accept != null && !accept(target)) continue;
    final file = File(target);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(member.readBytes() ?? Uint8List(0));
  }
}

/// A member's name: [path] under [from], with `/` between its parts whatever
/// this platform separates them with, which is what a zip names a path with.
String _member(String path, String from) =>
    p.split(p.relative(path, from: from)).join("/");
