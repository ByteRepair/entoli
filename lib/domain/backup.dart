import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:fs_shim/fs.dart";

import "../core/config.dart";
import "workspace.dart";

/// The whole data directory as a zip, and back again.
///
/// **The members are the files.** Each one is at the path it has under the data
/// directory, in its own bytes — so a backup opens in any file manager, a
/// conversation reads as itself, and one chat can be pulled out or put back by
/// hand. The layout is the format: a directory that grows a new kind of file is
/// backed up without this file being told about it.
///
/// It was one JSON document holding every file first, which is worse on every
/// count that matters. Text in JSON is escaped inside a string inside an array,
/// binary costs a third more as base64, nothing compresses, and JSON is read
/// whole — so an export would be bounded by what the device can hold twice
/// over, which a workspace the agent has run `npm install` in is not. Deflate
/// takes `conv.jsonl` to a fraction of itself, and a member is decompressed
/// only while it is being written out.
///
/// One member is not a file of the data directory: [manifestName], holding what
/// a reader has to agree with before anything is deleted. ZIP's own comment
/// field would have carried it — `archive` writes one — but reading it back
/// means reaching into `ZipDecoder.directory`, and it is decoded as latin-1. A
/// member is read through the same API as everything else, and is there for
/// whoever opens the file to read.
///
/// Restoring is only half of putting a backup back: what the app has already
/// read out of the data directory is the other half, and `AppRestart` is what
/// answers for it.

/// What the manifest says this is. A zip without one is refused before anything
/// has been deleted for it.
const backupFormat = "entoli-backup";

/// Bumped when a reader would have to be told something new. A manifest
/// claiming a higher one is refused rather than half-restored.
const backupVersion = 1;

/// The manifest's name in the archive — meta about the backup rather than a
/// file of the data directory, which is what the name says. Nothing creates a
/// file called this under the data directory; one that existed would be
/// shadowed by the manifest and left out of its own backup.
const manifestName = "backup-meta.json";

/// A backup that cannot be read. The message is shown to the user, so it says
/// what is wrong with the file rather than where the read gave up.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A backup that has been opened and agreed with, before anything has been done
/// with it. Its members are still compressed: what it can answer here it
/// answers out of the archive's directory, so a size or a count costs nothing.
class Backup {
  const Backup(this.archive, {this.createdAt});

  final Archive archive;

  /// Null where the manifest did not say, which a hand-made one may not.
  final DateTime? createdAt;

  /// Everything to restore: the archive without the manifest, which describes
  /// the backup rather than belonging to the data directory.
  Iterable<ArchiveFile> get entries =>
      archive.files.where((file) => file.name != manifestName);

  /// How many chats it holds, counted from the `state.json` each one has. Read
  /// out of the names rather than written into the manifest: a count stored
  /// beside the files is a count to keep in step with them.
  int get chats => entries
      .where((file) => file.name.split(RegExp(r"[/\\]")).last == "state.json")
      .length;

  /// What it comes to unpacked, which is the number worth saying — the file on
  /// disk is smaller and says nothing about what fits back.
  int get size => entries.fold(0, (total, file) => total + file.size);
}

/// Every file under the data directory, as the zip a backup is.
///
/// Not `zipEntries`, which names its members relative to the folder each one
/// sits in and takes everything it is given: this names them relative to the
/// data directory, skips a half-written file, and has a manifest to put in
/// first.
Future<Uint8List> writeBackup(AppConfig config) async {
  final fs = config.fs;
  final archive = Archive()
    ..add(ArchiveFile.string(
      manifestName,
      jsonEncode({
        "format": backupFormat,
        "version": backupVersion,
        "createdAt": DateTime.now().toUtc().toIso8601String(),
      }),
    ));
  await for (final found in _walk(fs, config.dataDir)) {
    final path = _relative(fs, config.dataDir, found.path);
    if (path.isEmpty || path == manifestName) continue;
    archive.add(found.isDirectory
        ? ArchiveFile.directory(path)
        : ArchiveFile.bytes(path, await fs.file(found.path).readAsBytes()));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Open a backup and check the manifest. Everything that can be refused is
/// refused here, so [restoreBackup] is only ever reached by a file that will
/// restore — nothing is deleted for a zip that turns out to be something else.
Backup parseBackup(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const BackupFormatException("it is not a zip file");
  }
  final manifest = archive.findFile(manifestName);
  if (manifest == null) {
    throw const BackupFormatException("it is not an Entoli backup");
  }
  final Object? document;
  try {
    document = jsonDecode(utf8.decode(manifest.readBytes() ?? const []));
  } catch (_) {
    throw const BackupFormatException("its manifest cannot be read");
  }
  if (document is! Map || document["format"] != backupFormat) {
    throw const BackupFormatException("it is not an Entoli backup");
  }
  final version = document["version"];
  if (version is! int || version > backupVersion) {
    throw const BackupFormatException("it was made by a newer version of Entoli");
  }
  return Backup(
    archive,
    createdAt: DateTime.tryParse(document["createdAt"] as String? ?? ""),
  );
}

/// Put a backup back. What is in the data directory now goes: a restore is what
/// was backed up, not that plus whatever has happened since, and a merge would
/// leave a chat deleted before the backup was made alive again beside one
/// written after it.
///
/// The caller drops what the app is holding in memory for the files about to be
/// replaced first — see `ChatRepository.importBackup`.
Future<void> restoreBackup(AppConfig config, Backup backup) async {
  final fs = config.fs;
  // Listed whole before anything goes: deleting out of a stream is deleting
  // the thing it is walking.
  for (final entity in await fs.directory(config.dataDir).list().toList()) {
    if (entity is Directory) {
      await entity.delete(recursive: true);
    } else {
      await entity.delete();
    }
  }

  // A member's name was written by whoever made the zip, so it goes through
  // `safeRelativePath` for the reason a shared file's path does: `../../` is a
  // name a zip can hold.
  final targets = {
    for (final file in backup.entries)
      file: fs.path.join(config.dataDir, safeRelativePath(fs, file.name)),
  };

  // Folders first and once each, files after and one at a time, for the reasons
  // `writeIncoming` does the same: `create` on the web opens a transaction
  // before it looks, and a member is decompressed as it is read, so writing
  // them at once would put the whole unpacked backup in memory.
  for (final folder in {
    for (final entry in targets.entries)
      entry.key.isDirectory ? entry.value : fs.path.dirname(entry.value),
  }) {
    await fs.directory(folder).create(recursive: true);
  }
  for (final entry in targets.entries) {
    if (entry.key.isDirectory) continue;
    await fs.file(entry.value).writeAsBytes(entry.key.readBytes() ?? Uint8List(0));
    // Landed, so the decompressed copy is no longer anybody's.
    entry.key.clear();
  }

  // A backup holding none of them is still a working app afterwards.
  await config.ensureDirs();
}

/// What the export writes the file as. The time is in it because two backups in
/// a day is what a person about to try something takes, and the share sheet on
/// Android has no dialog to rename the second one in.
String backupFilename(DateTime now) {
  String two(int value) => value.toString().padLeft(2, "0");
  return "entoli-backup-${now.year}-${two(now.month)}-${two(now.day)}"
      "-${two(now.hour)}${two(now.minute)}.zip";
}

/// Every file under [dir], and every directory that is empty — which is the one
/// kind a list of files cannot imply.
Stream<({String path, bool isDirectory})> _walk(FileSystem fs, String dir) async* {
  final entities = await fs.directory(dir).list().toList();
  if (entities.isEmpty) {
    yield (path: dir, isDirectory: true);
    return;
  }
  for (final entity in entities) {
    if (entity is Directory) {
      yield* _walk(fs, entity.path);
    } else if (!entity.path.endsWith(".writing")) {
      // The half of a rename that a kill landed in. Nothing reads one, and a
      // restore that put it back would put back a torn write.
      yield (path: entity.path, isDirectory: false);
    }
  }
}

String _relative(FileSystem fs, String dataDir, String path) {
  final relative = fs.path.relative(path, from: dataDir);
  return relative == "." ? "" : relative;
}
