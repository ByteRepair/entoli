import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:url_launcher/url_launcher.dart";
import "package:webview_flutter/webview_flutter.dart";

import "../../domain/link_opener.dart";

/// Opens links from rendered markdown.
///
/// On Android, `http`/`https` open in an in-app webview so the user stays in
/// the app; other schemes (`mailto:`, `tel:`) fall back to [url_launcher], which
/// a webview cannot load. Everywhere else — desktop and web — every URL goes to
/// the external browser via [url_launcher].
///
/// Not behind the conditional import in `platform.dart`: like `LauncherIcons`,
/// this branches at runtime with `kIsWeb` and `defaultTargetPlatform`, and a
/// platform with no webview implementation simply never takes the webview
/// branch. Keeps the app's one conditional import intact.
class PlatformLinkOpener implements LinkOpener {
  const PlatformLinkOpener();

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
}

/// A full-screen webview with an app bar, so a link tap keeps the user in the
/// app on Android rather than bouncing them out to the browser. The back
/// button walks webview history first and only then pops the route.
class _WebViewPage extends StatefulWidget {
  const _WebViewPage({required this.url});
  final Uri url;

  @override
  State<_WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<_WebViewPage> {
  late final WebViewController _controller;
  var _title = "";
  var _canGoBack = false;

  @override
  void initState() {
    super.initState();
    _title = widget.url.host;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) async {
            _title = await _controller.getTitle() ?? Uri.parse(url).host;
            _canGoBack = await _controller.canGoBack();
            if (mounted) setState(() {});
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  Future<void> _openExternally() => launchUrl(widget.url, mode: LaunchMode.externalApplication);

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