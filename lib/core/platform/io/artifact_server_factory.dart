import "../../../domain/artifact_server.dart";
import "artifact_server.dart" show IoArtifactServer;

/// Starts a local HTTP server serving [rootDir] on a random localhost port.
/// Used on Android, where the WebView blocks `file://` URLs.
Future<ArtifactServer> startArtifactServer(String rootDir) =>
    IoArtifactServer.start(rootDir);