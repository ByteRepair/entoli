import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:file/local.dart";
import "package:archive/archive_io.dart";
import "package:path/path.dart" as p;
import "package:entoli_core/model/config.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/migrations.dart";
import "package:entoli_core/store/zip.dart" show linkTargetOf;
import "package:entoli_core/model/documents.dart";
import "package:entoli_core/model/file_handoff.dart";
import "package:entoli_core/model/workspace.dart";
import "package:entoli_files/entoli_files.dart" show zipTo;

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

/// The provider keys, where the export was asked to carry them: meta beside
/// the manifest, since they are the secret store's and not a file of the
/// data directory. A restore hands them to the store.
const keysName = "backup-keys.json";

/// A backup that cannot be read. The message is shown to the user, so it says
/// what is wrong with the file rather than where the read gave up.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A backup that has been opened and agreed with, before anything has been done
/// with it: what the confirm says about it, read out of the archive's
/// directory, so a size or a count reads no member. The file is closed by the
/// time this exists; the restore opens it again by [path].
class Backup {
  const Backup._(
    this.path,
    this.members,
    this.chats,
    this.size, {
    this.createdAt,
    this.providerKeys = const {},
  });

  final String path;

  /// Every member's name but the manifest's, which describes the backup
  /// rather than belonging to the data directory.
  final List<String> members;

  /// How many chats it holds, counted from the `state.json` each one has rather
  /// than written into the manifest: a count stored beside the files is a count
  /// to keep in step with them.
  ///
  /// Matched against the layout rather than the basename, since the agent can
  /// have written a `state.json` of its own into a workspace and this is the
  /// number the user reads before agreeing to a restore.
  final int chats;

  /// What it comes to unpacked, which is the number worth saying — the file on
  /// disk is smaller and says nothing about what fits back.
  final int size;

  /// Null where the manifest did not say, which a hand-made one may not.
  final DateTime? createdAt;

  /// Each provider's key by its id, where the export carried them.
  final Map<String, String> providerKeys;
}

const _disk = LocalFileSystem();
const _workspace = Workspace(_disk);

/// `projects/<name>/chats/<id>/state.json`, which is where `AppConfig` puts one
/// and nowhere else.
final _chatState = RegExp(r"^projects/[^/]+/chats/[^/]+/state\.json$");

/// Every file under the data directory, as the zip a backup is, written to
/// [to] a member at a time — a backup costs disk, not memory — on an isolate of
/// its own, so a large file compressing does not hold up a frame.
/// [log] hears each top-level folder, and each one under it, as it goes in.
///
/// [providerKeys] go in beside the files where given, which is only where the
/// user asked for them.
Future<void> writeBackup(
  AppConfig config,
  String to, {
  StringSink? log,
  Map<String, String> providerKeys = const {},
}) async {
  final dataDir = config.dataDir;
  final machineLocal = config.machineLocalFiles;
  // The lines arrive on a port of their own, so they may trail the result:
  // the isolate's null is the last of them. The isolate's closure must
  // capture only what it names: a completer or the log would not cross.
  final progress = ReceivePort();
  final send = progress.sendPort;
  final zipped = Isolate.run(
    () => _zipData(dataDir, machineLocal, to, send, providerKeys),
  );
  await for (final line in progress) {
    if (line == null) break;
    log?.writeln(line);
  }
  await zipped;
}

/// The zip itself, on the isolate, ending its [progress] with a null.
Future<void> _zipData(
  String dataDir,
  List<String> machineLocal,
  String to,
  SendPort progress,
  Map<String, String> providerKeys,
) async {
  // A walk visits a folder's members together, so each is said once.
  String? last;
  try {
    final realDataDir = Directory(dataDir).resolveSymbolicLinksSync();
    await zipTo(
      to,
      [dataDir],
      base: dataDir,
      // The half of a rename that a kill landed in. Nothing reads one, and a
      // restore that put it back would put back a torn write.
      skip: (path) =>
          path.endsWith(writingSuffix) ||
          machineLocal.any((f) => p.equals(path, f)),
      // The top-level `sync/` holds private keys, and restoring it would
      // unpair this device. A project's `rootfs/` is re-fetchable and holds
      // proot's mode-0000 stubs the walker cannot list (see `tree_ops.dart`).
      // Matched by position: a workspace folder with either name is the
      // user's data.
      skipDir: (path) {
        final parts = p.split(p.relative(path, from: dataDir));
        return (parts.length == 1 && parts[0] == "sync") ||
            (parts.length == 3 &&
                parts[0] == "projects" &&
                parts[2] == "rootfs");
      },
      // What a backup holds is the data directory's: a link that leads out of
      // every project's workspace goes in as the link, not what it reaches.
      // Against the real path, since the data directory may sit under a link.
      followInto: (real) {
        final parts = p.split(p.relative(real, from: realDataDir));
        return parts.length >= 3 &&
            parts[0] == "projects" &&
            parts[2] == "workspace";
      },
      extra: [
        ArchiveFile.string(
          manifestName,
          jsonEncode({
            "format": backupFormat,
            "version": backupVersion,
            "createdAt": DateTime.now().toUtc().toIso8601String(),
          }),
        ),
        if (providerKeys.isNotEmpty)
          ArchiveFile.string(keysName, jsonEncode(providerKeys)),
      ],
      onMember: (name) {
        final parts = p.split(name);
        final folder = p.joinAll(parts.take(parts.length > 2 ? 2 : 1));
        if (folder != last) progress.send("Adding ${last = folder}");
      },
    );
  } finally {
    progress.send(null);
  }
}

/// Open the backup at [path] and check the manifest, on an isolate of its own:
/// the directory of a large zip is a read per member. Everything that can be
/// refused is refused here, before the user is asked, so the confirm is only
/// ever shown for a file that will restore.
Future<Backup> openBackup(String path) => Isolate.run(() async {
  final input = InputFileStream(path);
  try {
    final archive = _decoded(input);
    final members = [
      for (final file in archive.files)
        if (!_meta.contains(file.name)) file,
    ];
    return Backup._(
      path,
      [for (final file in members) file.name],
      members.where((file) => _chatState.hasMatch(file.name)).length,
      members.fold(0, (total, file) => total + file.size),
      createdAt: _createdAt(archive),
      providerKeys: _keysOf(archive),
    );
  } finally {
    await input.close();
  }
});

/// [input] as a backup's archive, refused where it is not one.
Archive _decoded(InputFileStream input) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeStream(input);
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
    throw const BackupFormatException(
      "it was made by a newer version of Entoli",
    );
  }
  return archive;
}

/// The members about the backup rather than of the data directory.
const _meta = {manifestName, keysName};

Map<String, String> _keysOf(Archive archive) {
  final file = archive.findFile(keysName);
  if (file == null) return const {};
  try {
    final keys = jsonDecode(utf8.decode(file.readBytes() ?? const []));
    return {
      if (keys is Map)
        for (final MapEntry(:key, :value) in keys.entries)
          if (value is String && value.isNotEmpty) "$key": value,
    };
  } on FormatException {
    throw const BackupFormatException("its provider keys cannot be read");
  }
}

DateTime? _createdAt(Archive archive) {
  final manifest = archive.findFile(manifestName)!.readBytes() ?? <int>[];
  final document = jsonDecode(utf8.decode(manifest)) as Map;
  return DateTime.tryParse(document["createdAt"] as String? ?? "");
}

/// Put a backup back. What is in the data directory now goes: a restore is what
/// was backed up, not that plus whatever has happened since, and a merge would
/// leave a chat deleted before the backup was made alive again beside one
/// written after it.
///
/// Unpacked beside the data directory rather than over it, then swapped in by
/// two renames, so a restore that fails on the way — a member that will not
/// write, a disk that fills — leaves the data directory as it was and takes
/// its own half-unpacked copy with it. The [AppConfig.machineLocalFiles] come
/// across from the directory being replaced. On an isolate of its own, so a
/// large member decompressing does not hold up a frame. The directory replaced
/// is left beside the restored one for [recoverRestore] to delete once the
/// app is back, rather than holding up the restart while a rootfs goes.
///
/// Nothing of the app may be running over these files while they are replaced,
/// which is `AppRestart`'s to arrange rather than this function's to check.
///
/// [deleteTree] clears what an earlier restore left. The platform's gets past
/// proot's mode-0000 stubs under `projects/<project>/rootfs/` and the
/// read-only skill directories.
Future<void> restoreBackup(
  AppConfig config,
  Backup backup, {
  required Future<void> Function(String path) deleteTree,
}) {
  final dataDir = config.dataDir;
  final machineLocal = config.machineLocalFiles;
  final from = backup.path;
  return Isolate.run(() => _restore(from, dataDir, machineLocal, deleteTree));
}

Future<void> _restore(
  String from,
  String dataDir,
  List<String> machineLocal,
  Future<void> Function(String path) deleteTree,
) async {
  final staged = restoringDirOf(dataDir);
  final replaced = replacedDirOf(dataDir);
  await _clear(staged, deleteTree);
  await _clear(replaced, deleteTree);

  try {
    await Directory(staged).create(recursive: true);
    final input = InputFileStream(from);
    try {
      final members = [
        for (final file in _decoded(input).files)
          if (!_meta.contains(file.name)) file,
      ];
      // A member's name was written by whoever made the zip, and
      // `writeIncoming` is where a path from outside is made safe to join
      // onto a directory.
      await _workspace.writeIncoming(staged, [
        for (final member in members)
          if (!member.isDirectory && linkTargetOf(member) == null)
            _RestoredFile(member),
      ]);
      for (final member in members) {
        if (linkTargetOf(member) case final target?) {
          await _restoreLink(staged, member.name, target);
        }
      }
      for (final member in members) {
        if (member.isDirectory) {
          await _workspace.createFolder(staged, member.name);
        }
      }
    } finally {
      await input.close();
    }
    for (final file in machineLocal) {
      if (File(file).existsSync()) {
        await File(file).copy(p.join(staged, p.relative(file, from: dataDir)));
      }
    }
    // A backup holding none of them is still a working app afterwards, and
    // one made by an older build unpacks that build's layout — including the
    // version stamp that says which one it is.
    await runMigrations(
      _disk,
      staged,
      fresh: await AppConfig.forDirectory(_disk, staged).ensureDirs(),
    );
  } catch (_) {
    await _clear(staged, deleteTree);
    rethrow;
  }

  await Directory(dataDir).rename(replaced);
  try {
    await Directory(staged).rename(dataDir);
  } catch (_) {
    await _putBack(dataDir);
    rethrow;
  }
}

/// A link the backup kept as one, put back at [name] under [staged]. Windows
/// makes one only with a privilege a user often lacks: a line, and the rest
/// of the restore goes on.
Future<void> _restoreLink(String staged, String name, String target) async {
  final at = p.join(staged, safeRelativePath(name));
  try {
    await Directory(p.dirname(at)).create(recursive: true);
    await Link(at).create(target);
  } on FileSystemException catch (e) {
    logFailure("backup", "a link could not be restored", e.osError);
  }
}

/// What a restore leaves to the next launch, called before the data directory
/// is read: a data directory missing beside the one a restore was replacing —
/// a kill between its two renames — is put back, since that one is still
/// whole, and the directory a finished restore replaced is deleted, unawaited,
/// so the app is not held up while a rootfs goes.
Future<void> recoverRestore(
  String dataDir, {
  required Future<void> Function(String path) deleteTree,
}) async {
  if (!Directory(dataDir).existsSync()) {
    await _putBack(dataDir);
    return;
  }
  unawaited(
    _clear(replacedDirOf(dataDir), deleteTree).catchError(
      (Object e) => logFailure("backup", "replaced data not deleted: $e"),
    ),
  );
}

Future<void> _putBack(String dataDir) async {
  final replaced = Directory(replacedDirOf(dataDir));
  if (replaced.existsSync()) await replaced.rename(dataDir);
}

/// Deletes [path] where it is there. A delete that raced another to the same
/// tree — the launch's sweep and a restore started straight after — is done
/// when the tree is gone, whichever of them finished it.
Future<void> _clear(
  String path,
  Future<void> Function(String path) deleteTree,
) async {
  if (!Directory(path).existsSync()) return;
  try {
    await deleteTree(path);
  } catch (_) {
    if (Directory(path).existsSync()) rethrow;
  }
}

/// Where a restore unpacks a backup before swapping it in, beside [dataDir] so
/// the swap is a rename on one filesystem.
String restoringDirOf(String dataDir) => "$dataDir.restoring";

/// Where a restore moves the data directory it replaces.
String replacedDirOf(String dataDir) => "$dataDir.replaced";

/// A member on its way out of the archive, which is what `IncomingFile` already
/// describes: bytes that have not been read yet, read once, as they are
/// written. Being able to add a variant from outside `file_handoff.dart` is why
/// that class is abstract rather than sealed.
class _RestoredFile extends IncomingFile {
  _RestoredFile(this.member) : super(member.name);

  final ArchiveFile member;

  @override
  Future<void> writeTo(File target) async {
    // Decompressed straight into the file, so the largest member costs a
    // buffer rather than its whole size. The restore is on the disk, which
    // is the only filesystem `OutputFileStream` writes.
    final output = OutputFileStream(target.path);
    try {
      member.writeContent(output);
    } finally {
      await output.close();
    }
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
