import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../../domain/artifact_style.dart";
import "../../domain/content_type.dart";

/// Serves [rootDir] over HTTP on a random localhost port. Used on the phones,
/// where the WebView blocks `file://` URLs — even with `setAllowFileAccess(true)`
/// — so local content is served over `http://` instead, which the WebView allows
/// without restriction. Stopped by [stop] when the viewer page is disposed.
///
/// HTML responses are run through [injectBaseStyles] before serving, so the
/// artifact gets the base stylesheet the viewer provides — the model writes
/// semantic HTML and the newspaper look is layered under whatever it adds.
class ArtifactServer {
  ArtifactServer._(this._server, this.rootDir);

  final HttpServer _server;
  final String rootDir;

  /// Start serving [rootDir] on a random localhost port.
  static Future<ArtifactServer> start(String rootDir) async {
    final server = await HttpServer.bind("127.0.0.1", 0);
    final instance = ArtifactServer._(server, rootDir);
    server.listen(instance._handle);
    return instance;
  }

  String get baseUrl => "http://127.0.0.1:${_server.port}";

  Future<void> _handle(HttpRequest request) async {
    final path = Uri.decodeComponent(request.uri.path.substring(1));
    // Decoding after the URI's dot-segment pass lets `..%2F` through, so the
    // decoded path is held to [rootDir] here.
    final resolved =
        p.normalize(p.join(rootDir, path.isEmpty ? "index.html" : path));
    final file = File(resolved);

    if (!p.isWithin(rootDir, resolved) || !await file.exists()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write("Not found: $path");
      await request.response.close();
      return;
    }

    final type = contentTypeFor(file.path);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.parse(type);

    // The base stylesheet rides under the model's own CSS, so it is injected
    // into HTML before serving. Other content types pass through unchanged.
    if (type == "text/html") {
      request.response.add(utf8.encode(injectBaseStyles(await file.readAsString())));
    } else {
      request.response.add(await file.readAsBytes());
    }
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}