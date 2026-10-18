import "dart:convert";
import "dart:js_interop";

import "package:web/web.dart" as web;

import "../../../domain/artifact_style.dart";
import "../../../domain/chat_store.dart";
import "../../../domain/content_type.dart";

/// The web implementation: reads the artifact's files from IndexedDB, builds
/// blob URLs for each, rewrites `index.html`'s relative references to point
/// at them, injects the base stylesheet, and opens the result in a new tab.
/// The name matches the io stub so the conditional import resolves to one
/// symbol on either platform.
class WebArtifactOpenerImpl {
  const WebArtifactOpenerImpl(this._store);

  final ChatStore _store;

  Future<void> open(String chatId, String artifactId, {required String entryFile}) async {
    final indexBytes = await _store.readArtifactFile(chatId, artifactId, entryFile);
    if (indexBytes == null) return;
    final indexHtml = injectBaseStyles(utf8.decode(indexBytes));

    final refs = _relativeRefs(indexHtml);
    final blobUrls = <String, String>{};
    final entries = await Future.wait(refs.map((ref) async {
      final bytes = await _store.readArtifactFile(chatId, artifactId, ref);
      if (bytes == null) return null;
      final type = contentTypeFor(ref);
      final blob = web.Blob(
        [bytes.toJS].toJS,
        web.BlobPropertyBag(type: type),
      );
      return (ref, web.URL.createObjectURL(blob));
    }));
    for (final e in entries.nonNulls) {
      blobUrls[e.$1] = e.$2;
    }

    final rewritten = _rewriteRefs(indexHtml, blobUrls);

    final blob = web.Blob(
      [utf8.encode(rewritten).toJS].toJS,
      web.BlobPropertyBag(type: "text/html"),
    );
    final url = web.URL.createObjectURL(blob);
    web.window.open(url, "_blank");
    Future.delayed(const Duration(seconds: 30), () {
      for (final u in blobUrls.values) {
        web.URL.revokeObjectURL(u);
      }
      web.URL.revokeObjectURL(url);
    });
  }
}

final _hrefOrSrc = RegExp("(href|src)=[\"']([^\"']+)[\"']");
final _external = RegExp(r"https?://|//|data:|#");

bool _isExternal(String path) => path.startsWith(_external);

Set<String> _relativeRefs(String html) {
  final refs = <String>{};
  for (final match in _hrefOrSrc.allMatches(html)) {
    final path = match.group(2)!;
    if (_isExternal(path)) continue;
    refs.add(path);
  }
  return refs;
}

String _rewriteRefs(String html, Map<String, String> mapping) {
  if (mapping.isEmpty) return html;
  return html.replaceAllMapped(_hrefOrSrc, (m) {
    final attr = m.group(1)!;
    final path = m.group(2)!;
    final replacement = mapping[path];
    if (replacement == null || _isExternal(path)) return m.group(0)!;
    return '$attr="$replacement"';
  });
}