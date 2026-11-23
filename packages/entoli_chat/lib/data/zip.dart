import "dart:io";
import "dart:typed_data";

import "package:archive/archive_io.dart";
import "package:path/path.dart" as p;

import "../domain/workspace.dart" show safeRelativePath;

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
    await for (final entry in walkTree(
      paths,
      base: base,
      skip: skip,
      skipDir: skipDir,
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
}) async {
  final archive = Archive();
  await for (final entry in walkTree(
    paths,
    base: base,
    skip: skip,
    skipDir: skipDir,
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
/// member at all, for a tree handed to someone else, where what it points at
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
  Stream<TreeEntry> walk(
    String from,
    String path,
    bool isDirectory, [
    Set<String> inside = const {},
  ]) async* {
    if (!isDirectory) {
      if (skip == null || !skip(path)) {
        yield (path: path, name: _member(path, from), isDirectory: false);
      }
      return;
    }
    if (skipDir != null && skipDir(path)) return;
    // Only the folders above it, not every folder seen: two links to one
    // folder elsewhere are two copies of it, not a loop.
    final real = followLinks
        ? Directory(path).resolveSymbolicLinksSync()
        : path;
    if (inside.contains(real)) return;
    final within = {...inside, real};
    // Its own entry as well as its contents': an empty folder is otherwise
    // nothing at all, and a zip of one alone would come out empty. The base
    // itself is not one of its own entries — `.` names nothing to unzip.
    final name = _member(path, from);
    if (name != ".") yield (path: path, name: name, isDirectory: true);
    // On the entity rather than its path: `list` has already answered which
    // each one is, and asking again is a stat per file.
    await for (final entity in Directory(path).list(followLinks: followLinks)) {
      if (entity is Link) continue;
      yield* walk(from, entity.path, entity is Directory, within);
    }
  }

  for (final path in paths) {
    yield* walk(
      base ?? p.dirname(path),
      path,
      FileSystemEntity.isDirectorySync(path),
    );
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
