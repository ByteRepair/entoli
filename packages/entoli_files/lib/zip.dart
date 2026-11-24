import "dart:io";

import "package:archive/archive_io.dart";
import "package:entoli_core/store/zip.dart";
import "package:file/local.dart";

/// Zip [paths] — files and folders alike — into a new file at [to]. Each
/// member is read and compressed in turn, straight into the file, so a tree of
/// any size costs one member's memory rather than the whole archive's. Entries
/// are named relative to [base], defaulting to each path's own parent, so
/// unzipping a folder gives the folder back rather than its contents loose.
/// [skip] drops a file by its path, and is never asked about a directory;
/// [skipDir] drops a directory by its path, and is asked before recursing into
/// it. [extra] goes in last, for a member of the caller's own. [followLinks]
/// and [followInto] are [walkTree]'s. [onMember] hears each member's name as
/// it is added, for a caller showing progress.
Future<void> zipTo(
  String to,
  List<String> paths, {
  String? base,
  bool Function(String path)? skip,
  bool Function(String path)? skipDir,
  List<ArchiveFile> extra = const [],
  bool followLinks = true,
  bool Function(String real)? followInto,
  void Function(String name)? onMember,
}) async {
  final encoder = ZipFileEncoder()..create(to);
  try {
    await for (final entry in walkTree(
      const LocalFileSystem(),
      paths,
      base: base,
      skip: skip,
      skipDir: skipDir,
      followLinks: followLinks,
      followInto: followInto,
    )) {
      if (entry.link case final link?) {
        encoder.addArchiveFile(linkMember(entry.name, link));
      } else if (entry.isDirectory) {
        encoder.addArchiveFile(ArchiveFile.directory(entry.name));
      } else {
        await _addStreamed(encoder, entry.path, entry.name);
      }
      onMember?.call(entry.name);
    }
    extra.forEach(encoder.addArchiveFile);
  } finally {
    await encoder.close();
  }
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
