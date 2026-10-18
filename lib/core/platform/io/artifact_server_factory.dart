import "../../../domain/artifact_server.dart";
import "artifact_server.dart" show IoArtifactServer;

/// Starts a local HTTP server serving [rootDir] on a random localhost port.
/// Used on the phones, whose webviews will not load `file://` URLs.
Future<ArtifactServer> startArtifactServer(String rootDir) =>
    IoArtifactServer.start(rootDir);