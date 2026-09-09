import "dart:typed_data";

/// What the hub answers about a mirrored chat's artifacts: the one zip of its
/// files, or null where the artifact is not there. Declared here rather than
/// in either branch of `remote_artifact.dart`'s conditional import, because a
/// type reached through one would be a different type on the other — [SyncHub]
/// implements it once, everywhere, and both branches refer to this one.
abstract interface class ArtifactBytes {
  Future<Uint8List?> artifactBytes(String chatId, String artifactId);
}
