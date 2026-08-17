import "dart:io";

import "../../../domain/artifact_server.dart";
import "../../../domain/content_type.dart";

/// Serves [rootDir] over HTTP on a random localhost port. Used on Android,
/// where the WebView blocks `file://` URLs — even with `setAllowFileAccess(true)`
/// — so local content is served over `http://` instead, which the WebView allows
/// without restriction. Stopped by [stop] when the viewer page is disposed.
class IoArtifactServer implements ArtifactServer {
  IoArtifactServer._(this._server, this.rootDir);

  final HttpServer _server;
  final String rootDir;

  /// Start serving [rootDir] on a random localhost port.
  static Future<ArtifactServer> start(String rootDir) async {
    final server = await HttpServer.bind("127.0.0.1", 0);
    final instance = IoArtifactServer._(server, rootDir);
    server.listen(instance._handle);
    return instance;
  }

  @override
  String get baseUrl => "http://127.0.0.1:${_server.port}";

  Future<void> _handle(HttpRequest request) async {
    final path = Uri.decodeComponent(request.uri.path.substring(1));
    final file = File("$rootDir/${path.isEmpty ? 'index.html' : path}");

    if (!await file.exists()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write("Not found: $path");
      await request.response.close();
      return;
    }

    final bytes = await file.readAsBytes();
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.parse(contentTypeFor(file.path))
      ..add(bytes);
    await request.response.close();
  }

  @override
  Future<void> stop() => _server.close(force: true);
}