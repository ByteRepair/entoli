import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:fs_shim/fs.dart";

import "../core/config.dart";
import "../core/migrations.dart";
import "../domain/documents.dart";
import "../domain/file_handoff.dart";
import "../domain/workspace.dart";
import "zip.dart";

/// The whole data directory as a zip, and back again. The members are the
/// files, at the paths they have under the data directory. See AGENTS.md,
/// "Backing it all up".

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
/// with it. Its members are still compressed: what it answers here it answers
/// out of the archive's directory, so a size or a count reads no bytes.
class Backup {
  const Backup(this.archive, {this.createdAt});

  final Archive archive;

  /// Null where the manifest did not say, which a hand-made one may not.
  final DateTime? createdAt;

  /// Everything to restore: the archive without the manifest, which describes
  /// the backup rather than belonging to the data directory.
  Iterable<ArchiveFile> get entries =>
      archive.files.where((file) => file.name != manifestName);

  /// How many chats it holds, counted from the `state.json` each one has rather
  /// than written into the manifest: a count stored beside the files is a count
  /// to keep in step with them.
  ///
  /// Matched against the layout rather than the basename, since the agent can
  /// have written a `state.json` of its own into a workspace and this is the
  /// number the user reads before agreeing to a restore.
  int get chats => entries.where((file) => _chatState.hasMatch(file.name)).length;

  /// What it comes to unpacked, which is the number worth saying — the file on
  /// disk is smaller and says nothing about what fits back.
  int get size => entries.fold(0, (total, file) => total + file.size);
}

/// `projects/<name>/chats/<id>/state.json`, which is where `AppConfig` puts one
/// and nowhere else.
final _chatState = RegExp(r"^projects/[^/]+/chats/[^/]+/state\.json$");

/// Every file under the data directory, as the zip a backup is.
///
/// The whole archive is built and encoded in memory, so an export is bounded by
/// what the device can hold — `autoClose` frees each member as it is
/// compressed, which is the half of that it is possible to give back here.
/// Streaming the encode to a file would need `archive_io`, which a browser
/// cannot have.
Future<Uint8List> writeBackup(AppConfig config) async {
  final archive = await archiveOf(
    config.fs,
    [config.dataDir],
    base: config.dataDir,
    // The half of a rename that a kill landed in. Nothing reads one, and a
    // restore that put it back would put back a torn write.
    skip: (path) => path.endsWith(writingSuffix),
    // The top-level `sync/` holds private keys, and restoring it would unpair
    // this device. A project's `rootfs/` is re-fetchable and holds proot's
    // mode-0000 stubs the walker cannot list (see `tree_ops.dart`). Matched by
    // position: a workspace folder with either name is the user's data.
    skipDir: (path) {
      final parts =
          config.fs.path.split(config.fs.path.relative(path, from: config.dataDir));
      return (parts.length == 1 && parts[0] == "sync") ||
          (parts.length == 3 && parts[0] == "projects" && parts[2] == "rootfs");
    },
  );
  archive.add(ArchiveFile.string(
    manifestName,
    jsonEncode({
      "format": backupFormat,
      "version": backupVersion,
      "createdAt": DateTime.now().toUtc().toIso8601String(),
    }),
  ));
  return ZipEncoder().encodeBytes(archive, autoClose: true);
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
/// Nothing of the app may be running over these files while they are replaced,
/// which is `AppRestart`'s to arrange rather than this function's to check.
///
/// [deleteTree] clears each top-level directory. The io side's gets past
/// proot's mode-0000 stubs under `projects/<project>/rootfs/`, which the plain
/// recursive delete used by default (enough on the web) dies on.
Future<void> restoreBackup(
  AppConfig config,
  Backup backup, {
  Future<void> Function(String path)? deleteTree,
}) async {
  final fs = config.fs;
  Future<void> clear(String path) async =>
      deleteTree != null ? deleteTree(path) : fs.directory(path).delete(recursive: true);

  // Listed whole first: deleting out of a stream deletes what it walks.
  final top = await fs.directory(config.dataDir).list().toList();
  await Future.wait([
    for (final entity in top)
      if (entity is Directory)
        clear(entity.path)
      else if (entity is File)
        entity.delete(),
  ]);

  // A member's name was written by whoever made the zip, and `writeIncoming`
  // is where a path from outside is made safe to join onto a directory.
  await writeIncoming(fs, config.dataDir, [
    for (final member in backup.entries)
      if (!member.isDirectory) _RestoredFile(member),
  ]);
  for (final member in backup.entries) {
    if (member.isDirectory) await createFolder(fs, config.dataDir, member.name);
  }

  // A backup holding none of them is still a working app afterwards, and one
  // made by an older build unpacks that build's layout — including the version
  // stamp that says which one it is.
  await runMigrations(config, fresh: await config.ensureDirs());
}

/// A member on its way out of the archive, which is what `IncomingFile` already
/// describes: bytes that have not been read yet, read once, and consumed by the
/// write. Being able to add a variant from outside `file_handoff.dart` is why
/// that class is abstract rather than sealed.
class _RestoredFile extends IncomingFile {
  _RestoredFile(this.member) : super(member.name);

  final ArchiveFile member;

  @override
  Future<void> writeTo(FileSystem fs, String target) async {
    await fs.file(target).writeAsBytes(member.readBytes() ?? Uint8List(0));
    // Landed, so the decompressed copy is no longer anybody's.
    member.clear();
  }
}

/// What the export writes the file as. The time is in it because two backups in
/// a day is what a person about to try something takes, and the share sheet on
/// Android has no dialog to rename the second one in.
String backupFilename(DateTime now) {
  String two(int value) => value.toString().padLeft(2, "0");
  return "entoli-backup-${now.year}-${two(now.month)}-${two(now.day)}"
      "-${two(now.hour)}${two(now.minute)}.zip";
}
