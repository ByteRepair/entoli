import "../../../domain/artifact_server.dart";

/// Web stub. Web uses blob URLs, not a local HTTP server. The conditional
/// import in `link_opener.dart` swaps this in on web so `dart:io` never
/// reaches a browser build.
Future<ArtifactServer> startArtifactServer(String rootDir) async {
  throw UnsupportedError("ArtifactServer is not available on web");
}