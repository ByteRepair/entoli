import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:url_launcher/url_launcher.dart";
import "package:webview_flutter/webview_flutter.dart";

import "../core/log.dart";
import "../core/platform/io/artifact_server_factory.dart"
    if (dart.library.js_interop) "../core/platform/web/artifact_server_factory.dart"
    show startArtifactServer;
import "../core/platform/io/web_artifact_opener.dart"
    if (dart.library.js_interop) "../core/platform/web/web_artifact_opener.dart"
    show WebArtifactOpenerImpl;
import "../domain/artifact_server.dart";
import "../domain/chat_store.dart";
import "../domain/link_opener.dart";
import "widgets/dialogs.dart";

/// Opens links from rendered markdown, and artifacts the model rendered.
///
/// On Android, `http`/`https` open in an in-app webview so the user stays in
/// the app; other schemes (`mailto:`, `tel:`) fall back to [url_launcher], which
/// a webview cannot load. Everywhere else — desktop and web — every URL goes to
/// the external browser via [url_launcher].
///
/// Artifacts open the same way on Android (in-app webview) and desktop (external
/// browser). Android serves the artifact over a local HTTP server because the
/// WebView blocks `file://` URLs on modern Android. On web, where there is no
/// filesystem path, the artifact's files are read from IndexedDB and assembled
/// into blob URLs — one per file, with `index.html`'s relative links rewritten
/// to point at them — and the result opens in a new tab. That web logic lives
/// behind a conditional import so `package:web` never reaches a native build.
class PlatformLinkOpener implements LinkOpener {
  const PlatformLinkOpener(this._store);

  final ChatStore _store;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> open(BuildContext context, Uri url) async {
    if (_isAndroid && (url.scheme == "http" || url.scheme == "https")) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => _WebViewPage(url: url)),
      );
      return;
    }
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Future<void> openArtifact(
    BuildContext context,
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) async {
    if (kIsWeb) {
      await WebArtifactOpenerImpl(_store).open(chatId, artifactId, entryFile: entryFile);
      return;
    }
    final dir = await _store.artifactPath(chatId, artifactId);
    if (!_isAndroid) {
      await _openDesktopArtifact(chatId, artifactId, dir, entryFile);
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ArtifactWebViewPage(dir: dir, entryFile: entryFile, title: title),
      ),
    );
  }

  /// Desktop opens the artifact's entry file itself: the store injects the
  /// base stylesheet into it at publish time, so the file on disk is the
  /// whole page and `file://` resolves its relative references — images,
  /// scripts — against the artifact directory they sit in. Nothing is copied
  /// to a temp location, because the copy would break exactly those paths.
  /// The existence check goes through the store rather than `dart:io`, which
  /// must stay off this file's web build.
  Future<void> _openDesktopArtifact(
      String chatId, String artifactId, String dir, String entryFile) async {
    final bytes = await _store.readArtifactFile(chatId, artifactId, entryFile);
    if (bytes == null) {
      logFailure("open", "Artifact entry file missing: $dir/$entryFile");
      return;
    }
    await launchUrl(Uri.file("$dir/$entryFile"),
        mode: LaunchMode.externalApplication);
  }
}

/// A full-screen webview for browsing a web page on Android, so a link tap
/// keeps the user in the app rather than bouncing them out to the browser.
/// The back button walks webview history first and only then pops the route.
/// Copy link and Open in browser act on the page navigated to rather than the
/// link that opened it, which is why `_url` follows the webview.
class _WebViewPage extends StatefulWidget {
  const _WebViewPage({required this.url});
  final Uri url;

  @override
  State<_WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<_WebViewPage> {
  late final WebViewController _controller;
  late Uri _url;
  var _title = "";
  var _canGoBack = false;

  @override
  void initState() {
    super.initState();
    _url = widget.url;
    _title = widget.url.host;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Fires without a page load too, which is the only notice a
          // history-rewriting page gives.
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) _url = Uri.parse(url);
          },
          onPageFinished: (url) async {
            _url = Uri.parse(url);
            _title = await _controller.getTitle() ?? _url.host;
            _canGoBack = await _controller.canGoBack();
            if (mounted) setState(() {});
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  Future<void> _openExternally() => launchUrl(_url, mode: LaunchMode.externalApplication);

  Future<void> _copyLink() => copyToClipboard(context, _url.toString(), said: "Copied link");

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_canGoBack,
        onPopInvokedWithResult: (didPop, _) async {
          if (!didPop && _canGoBack) await _controller.goBack();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(_title, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: "Copy link",
                onPressed: _copyLink,
              ),
              IconButton(
                icon: const Icon(Icons.open_in_browser),
                tooltip: "Open in browser",
                onPressed: _openExternally,
              ),
            ],
          ),
          body: WebViewWidget(controller: _controller),
        ),
      );
}

/// An artifact viewer that serves the artifact's files over a local HTTP
/// server, since Android's WebView blocks `file://` URLs. The server starts
/// in `initState` and stops in `dispose`, so it lives only while the page
/// is on screen — which is why this one has no Copy link or Open in browser:
/// its URL is a port that is gone by the time anything else could follow it.
class _ArtifactWebViewPage extends StatefulWidget {
  const _ArtifactWebViewPage({required this.dir, required this.entryFile, this.title});
  final String dir;
  final String entryFile;
  final String? title;

  @override
  State<_ArtifactWebViewPage> createState() => _ArtifactWebViewPageState();
}

class _ArtifactWebViewPageState extends State<_ArtifactWebViewPage> {
  WebViewController? _controller;
  ArtifactServer? _server;
  var _title = "";
  var _canGoBack = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = widget.title ?? "Artifact";
    _start();
  }

  Future<void> _start() async {
    try {
      _server = await startArtifactServer(widget.dir);
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (url) async {
              _title = await _controller!.getTitle() ?? "Artifact";
              _canGoBack = await _controller!.canGoBack();
              if (mounted) setState(() {});
            },
          ),
        )
        ..loadRequest(Uri.parse("${_server!.baseUrl}/${widget.entryFile}"));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Failed to open artifact: $e");
      }
    }
  }

  @override
  void dispose() {
    _server?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Artifact")),
        body: Center(child: Text(_error!)),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        appBar: AppBar(title: Text(_title, overflow: TextOverflow.ellipsis)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _canGoBack) await controller.goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title, overflow: TextOverflow.ellipsis),
        ),
        body: WebViewWidget(controller: controller),
      ),
    );
  }
}