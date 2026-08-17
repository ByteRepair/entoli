/// A temporary local HTTP server that serves an artifact's files on Android,
/// where the WebView blocks `file://` URLs. The real implementation is behind
/// a conditional import (`dart:io` on native, no-op on web). The server lives
/// only for the duration of the artifact viewer page.
abstract interface class ArtifactServer {
  String get baseUrl;
  Future<void> stop();
}