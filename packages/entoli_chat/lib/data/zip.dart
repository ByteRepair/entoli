import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:file/file.dart";
import "package:path/path.dart" as p;

import "../core/log.dart";
import "../domain/workspace.dart" show safeRelativePath;

/// The walk `zipTo` streams to a file, held in memory: for the small trees — a
/// skill, an artifact — whose zip goes out as bytes.
Future<Archive> archiveOf(
  FileSystem fs,
  List<String> paths, {
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
  bool followLinks = true,
}) async {
  final archive = Archive();
  await for (final entry in walkTree(
    fs,
    paths,
    base: base,
    skip: skip,
    skipDir: skipDir,
    followLinks: followLinks,
  )) {
    archive.add(
      entry.link != null
          ? linkMember(entry.name, entry.link!)
          : entry.isDirectory
          ? ArchiveFile.directory(entry.name)
          : ArchiveFile.bytes(
              entry.name,
              await fs.file(entry.path).readAsBytes(),
            ),
    );
  }
  return archive;
}

/// What the archive is called: the folder that was picked, or the one
/// everything selected sits in.
String zipNameFor(List<String> paths) {
  final named = paths.length == 1 ? paths.single : p.dirname(paths.first);
  return "${p.basename(named)}.zip";
}

/// A link as a zip member, as a Unix `zip` writes one: its target as the
/// content, and a mode whose type bits say link. The encoder here marks every
/// zip as made on MS-DOS, which its decoder then reads no link from, so
/// [linkTargetOf] reads the mode itself.
ArchiveFile linkMember(String name, String target) =>
    ArchiveFile.bytes(name, utf8.encode(target))..mode = 0xa1ff;

/// What [member] links to, where it is a link [linkMember] made.
String? linkTargetOf(ArchiveFile member) => member.mode & 0xf000 == 0xa000
    ? utf8.decode(member.readBytes() ?? Uint8List(0))
    : null;

/// One member [walkTree] makes: its [path] on disk, and its [name] in a zip.
/// [link] is set where the member is a link kept as one, to what it names.
typedef TreeEntry = ({
  String path,
  String name,
  bool isDirectory,
  String? link,
});

/// Every member [paths] make on [fs], in walk order: each folder before what
/// is in it, named relative to [base] or the path's own parent. A link is
/// followed, so a member is what the link points at; with [followLinks] false
/// it is no member at all, even as one of [paths], for a tree handed to
/// someone else, where what it points at outside itself is not the tree's to
/// give. A link to a folder the walk is already inside is never a member,
/// which would never end. [followInto] is asked where a link lands, by its
/// real path: refused, or broken, the link is a member as the link, with
/// nothing it leads to; without it a broken link is no member. [skip] drops a
/// file by its path, and is never asked about a directory; [skipDir] drops a
/// directory by its path, and is asked before recursing into it.
Stream<TreeEntry> walkTree(
  FileSystem fs,
  List<String> paths, {
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
  bool followLinks = true,
  bool Function(String real)? followInto,
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
        yield (
          path: path,
          name: _member(path, from),
          isDirectory: false,
          link: null,
        );
      }
      return;
    }
    if (skipDir != null && skipDir(path)) return;
    if (real != null && !inside.add(real)) return;
    // Its own entry as well as its contents': an empty folder is otherwise
    // nothing at all, and a zip of one alone would come out empty. The base
    // itself is not one of its own entries — `.` names nothing to unzip.
    final name = _member(path, from);
    if (name != ".") {
      yield (path: path, name: name, isDirectory: true, link: null);
    }
    // Listed without following, so only a link costs a lookup of where it
    // lands: a folder that is not one is its parent's real path and its name.
    await for (final entity in fs.directory(path).list(followLinks: false)) {
      if (entity is! Link) {
        final isDir = entity is Directory;
        yield* walk(
          from,
          entity.path,
          isDir,
          isDir && real != null ? p.join(real, p.basename(entity.path)) : null,
        );
      } else if (followLinks) {
        final type = fs.typeSync(entity.path);
        if (followInto != null) {
          // A broken link leads nowhere in scope either: kept, like one out.
          final real = type == FileSystemEntityType.notFound
              ? null
              : _realOf(fs, entity.path);
          if (real == null || !followInto(real)) {
            yield (
              path: entity.path,
              name: _member(entity.path, from),
              isDirectory: false,
              link: entity.targetSync(),
            );
            continue;
          }
        }
        switch (type) {
          case FileSystemEntityType.file:
            yield* walk(from, entity.path, false, null);
          case FileSystemEntityType.directory:
            final target = _realOf(fs, entity.path);
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
    if (!followLinks && fs.isLinkSync(path)) continue;
    final isDirectory = fs.isDirectorySync(path);
    yield* walk(
      base ?? p.dirname(path),
      path,
      isDirectory,
      followLinks && isDirectory ? _realOf(fs, path) : null,
    );
  }
}

/// [path] with its links resolved, or null where it went between being
/// listed and being asked.
String? _realOf(FileSystem fs, String path) {
  try {
    return fs.directory(path).resolveSymbolicLinksSync();
  } on FileSystemException catch (e) {
    logFailure("files", "a link could not be resolved", e.osError);
    return null;
  }
}

/// [archive]'s files written out under [dir]. Each name goes through
/// [safeRelativePath] first, so `../x` lands inside [dir] rather than beside
/// it; [accept] drops a member by the path it would be written to.
Future<void> extractInto(
  FileSystem fs,
  Archive archive,
  String dir, {
  bool Function(String target)? accept,
}) async {
  for (final member in archive) {
    if (member.isDirectory) continue;
    final target = p.join(dir, safeRelativePath(member.name));
    if (accept != null && !accept(target)) continue;
    final file = fs.file(target);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(member.readBytes() ?? Uint8List(0));
  }
}

/// A member's name: [path] under [from], with `/` between its parts whatever
/// this platform separates them with, which is what a zip names a path with.
String _member(String path, String from) =>
    p.split(p.relative(path, from: from)).join("/");
