import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "../../../data/sync/artifact_bytes.dart" show ArtifactBytes;
import "../../../domain/workspace.dart";
import "../../log.dart";

/// The mirror-side half of opening a remote artifact: the bytes come off the
/// sync channel, are written to a temporary directory, and every platform
/// viewer — `file://` on the desktop, the loopback HTTP server on Android —
/// is the one the local artifact already had, which is why this writes a
/// real directory rather than adding a second viewer over memory.
///
/// Member names came from wherever the zip was made, so each goes through
/// [safeRelativePath] before joining the temp root — a name like
/// `../x.html` lands flattened inside the directory instead of outside it.
Future<String> unzipRemoteArtifact(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp("entoli-artifact");
  for (final member in ZipDecoder().decodeBytes(bytes)) {
    if (member.isDirectory) continue;
    final target =
        "${dir.path}/${safeRelativePath(fileSystemIo, member.name)}";
    final file = File(target);
    await file.create(recursive: true);
    await file.writeAsBytes(member.readBytes() ?? Uint8List(0));
  }
  return dir.path;
}

/// Fetches an artifact of a mirrored chat and stages it in a temp directory,
/// answering where it landed or null where the fetch or the zip came up
/// short. The directories it makes are its own to keep: the previous one for
/// the same chat and artifact goes only when the next one is in place, since
/// an external viewer may still be reading it long after the tap that made it.
class RemoteArtifacts {
  /// The one call into the hub is [ArtifactBytes.artifactBytes]; the
  /// interface keeps this testable without a hub on a loopback under it.
  RemoteArtifacts(ArtifactBytes hub) : _hub = hub;

  final ArtifactBytes _hub;

  /// The staged directories, by chat and artifact. A desktop open never has
  /// a dispose to clean up in, so the newest replaces the older.
  final _staged = <String, String>{};

  Future<String?> fetch(String chatId, String artifactId,
      {required String entryFile}) async {
    final bytes = await _hub.artifactBytes(chatId, artifactId);
    if (bytes == null || bytes.isEmpty) return null;
    final dir = await unzipRemoteArtifact(bytes);
    final key = "$chatId/$artifactId";
    // The entry file is checked before the old directory goes, so a zip
    // missing it costs nothing that was already on screen.
    final usable = File("$dir/$entryFile").existsSync();
    if (usable) {
      final previous = _staged[key];
      _staged[key] = dir;
      if (previous != null) _discard(previous);
    } else {
      _discard(dir);
    }
    return usable ? dir : null;
  }

  void _discard(String dir) {
    Directory(dir)
        .delete(recursive: true)
        .then((_) {}, onError: (Object e) => logFailure("open", "$e"));
  }
}