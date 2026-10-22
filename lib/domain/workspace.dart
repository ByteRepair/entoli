import "dart:convert";
import "dart:typed_data";

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

/// The most of a file the viewer reads. A workspace holds the agent's logs, so
/// there is no upper bound on what a tap can land on; why this much is in
/// `lib/ui/workspace/AGENTS.md`.
const textViewLimit = 4 * 1024 * 1024;

/// The most markdown the viewer renders; past it, the source is shown instead.
const markdownPreviewLimit = 256 * 1024;

class WorkspaceText {
  const WorkspaceText(this.text, {required this.truncated});

  final String text;
  final bool truncated;
}

/// Whether the viewer should try [name] at all — the half of the rule that
/// decides without a read, [readTextHead] being the other.
///
/// No extension counts, since `README` and `Makefile` have none; a dotfile
/// reaches that same branch because `package:path` reads a leading dot as a
/// name rather than as an extension.
bool looksTextual(FileSystem fs, String name) {
  final extension = fs.path.extension(name).toLowerCase();
  return extension.isEmpty || _textExtensions.contains(extension.substring(1));
}

const _textExtensions = {
  "txt", "md", "markdown", "rst", "log", "csv", "tsv",
  "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "lock",
  "xml", "html", "htm", "css", "scss", "svg", "diff", "patch", "properties",
  "dart", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "sh", "bash", "zsh",
  "fish", "c", "h", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "kts",
  "swift", "rb", "php", "lua", "sql", "r", "m", "pl", "vim", "gradle",
};

/// Read at most [textViewLimit] bytes of [path] as UTF-8, or `null` if what
/// came back is not text after all — a `.log` the agent wrote as a gzip is a
/// hand-off rather than a page of mojibake.
Future<WorkspaceText?> readTextHead(FileSystem fs, String path) async {
  final stat = await fs.file(path).stat();
  if (stat.type != FileSystemEntityType.file) {
    throw Exception("$path is no longer there");
  }
  final truncated = stat.size > textViewLimit;
  final end = truncated ? textViewLimit : stat.size;
  final read = BytesBuilder(copy: false);
  await for (final chunk in fs.file(path).openRead(0, end)) {
    read.add(chunk);
  }
  var bytes = read.takeBytes();
  if (bytes.contains(0)) return null;
  if (truncated) bytes = _withoutCutRune(bytes);
  try {
    return WorkspaceText(utf8.decode(bytes), truncated: truncated);
  } on FormatException {
    return null;
  }
}

/// The cap falls on a byte, so the last character can be half of one. Dropping
/// it is the difference between a truncated file and one that reads as binary.
///
/// The walk back stops at four, since no UTF-8 rune is longer than that.
Uint8List _withoutCutRune(Uint8List bytes) {
  var start = bytes.length - 1;
  while (start >= 0 && bytes.length - start < 4 && bytes[start] & 0xc0 == 0x80) {
    start--;
  }
  if (start < 0 || bytes[start] < 0xc0) return bytes;
  final needed = bytes[start] >= 0xf0 ? 4 : (bytes[start] >= 0xe0 ? 3 : 2);
  return bytes.length - start >= needed ? bytes : Uint8List.sublistView(bytes, 0, start);
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

Future<void> createFolder(FileSystem fs, String dir, String name) => fs
    .directory(fs.path.join(dir, safeRelativePath(fs, name)))
    .create(recursive: true);

/// Remove [paths], each with whatever is under it. One already gone is a
/// deletion that happened.
///
/// The lookups go out in one wave and the deletions in another, for the reason
/// [listWorkspace] stats in one: a selection is a folder's siblings, so nothing
/// here is ordered, and awaiting per path is one IndexedDB transaction at a
/// time in front of the busy bar.
Future<void> deleteEntries(FileSystem fs, List<String> paths) async {
  final types = await Future.wait(paths.map(fs.type));
  await Future.wait([
    for (final (index, path) in paths.indexed)
      if (types[index] == FileSystemEntityType.directory)
        fs.directory(path).delete(recursive: true)
      else if (types[index] != FileSystemEntityType.notFound)
        fs.file(path).delete(),
  ]);
}

/// A path from outside, made safe to join onto a workspace. `..` and a leading
/// separator are what this exists for: a shared file names itself, and one
/// naming `../../settings.json` would otherwise be written there. Everything
/// left is kept, so a folder upload keeps its shape.
/// Whether [path] is [root] itself or under it, for two resolved paths. The
/// check is an exact prefix plus a separator, so a sibling that only shares
/// the root's spelling — `/workspace` and `/workspace-two` — is not under it.
bool isUnder(FileSystem fs, String path, String root) =>
    path == root || path.startsWith("$root${fs.path.separator}");

/// A path from outside, made safe to join onto a workspace. `..` and a leading
/// separator are what this exists for: a shared file names itself, and one
/// naming `../../settings.json` would otherwise be written there. Everything
/// left is kept, so a folder upload keeps its shape.
String safeRelativePath(FileSystem fs, String path) {
  final segments = path
      .split(_separator)
      .where((s) => s.isNotEmpty && s != "." && s != "..")
      .map(_safeSegment)
      .toList();
  return segments.isEmpty ? "file" : segments.join(fs.path.separator);
}

/// A drive letter or a colon is a path on Windows and a filename everywhere
/// else, so it goes with the rest of what a filesystem will not take.
String _safeSegment(String segment) {
  final safe = segment.replaceAll(_unsafe, "_").trim();
  return safe.isEmpty ? "file" : safe;
}

/// Both compiled once. A restore runs this per archive entry and per segment of
/// each, where a pattern built per call is a compile per segment.
final _separator = RegExp(r"[/\\]");
final _unsafe = RegExp(r'[\x00-\x1f<>:"|?*]');
