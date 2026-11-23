import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:file/local.dart";

import "../../data/sync/artifact_bytes.dart" show ArtifactBytes;
import "package:entoli_chat/core/log.dart";
import "package:entoli_chat/data/zip.dart" show extractInto;

/// The mirror-side half of opening a remote artifact: the bytes come off the
/// sync channel, are written to a temporary directory, and every platform
/// viewer — `file://` on the desktop, the loopback HTTP server on Android —
/// is the one the local artifact already had, which is why this writes a
/// real directory rather than adding a second viewer over memory.
///
/// Member names came from wherever the zip was made, which [extractInto]
/// holds inside the temp root.
Future<String> unzipRemoteArtifact(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp("entoli-artifact");
  await extractInto(
    const LocalFileSystem(),
    ZipDecoder().decodeBytes(bytes),
    dir.path,
  );
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

  Future<String?> fetch(
    String chatId,
    String artifactId, {
    required String entryFile,
  }) async {
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
