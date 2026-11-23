import "package:entoli_core/view/web_view.dart";
import "package:flutter/material.dart";
import "package:webview_flutter/webview_flutter.dart";
import "package:webview_flutter_android/webview_flutter_android.dart";

/// `webview_flutter`'s web view.
class PluginWebView implements WebView {
  const PluginWebView();

  @override
  Widget view({
    required Uri url,
    void Function(Uri url, String? title)? onNavigated,
  }) => _WebPageView(url: url, onNavigated: onNavigated);
}

class _WebPageView extends StatefulWidget {
  const _WebPageView({required this.url, this.onNavigated});

  final Uri url;
  final void Function(Uri url, String? title)? onNavigated;

  @override
  State<_WebPageView> createState() => _WebPageViewState();
}

class _WebPageViewState extends State<_WebPageView> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (url) async {
          final back = await _controller.canGoBack();
          if (mounted && back != _canGoBack) setState(() => _canGoBack = back);
          await _said(url);
        },
        // A page that rewrites its address without loading is somewhere new.
        onUrlChange: (change) => _said(change.url),
      ),
    )
    ..loadRequest(widget.url);
  var _canGoBack = false;

  Future<void> _said(String? url) async {
    final at = url == null ? null : Uri.tryParse(url);
    if (at == null) return;
    final title = await _controller.getTitle();
    if (mounted) widget.onNavigated?.call(at, title);
  }

  @override
  Widget build(BuildContext context) {
    final platform = _controller.platform;
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _canGoBack) await _controller.goBack();
      },
      // The plugin's Android default draws into a texture Flutter
      // composites, which lags scrolling by a frame; hybrid composition
      // puts the native view on screen to scroll by itself.
      child: WebViewWidget.fromPlatformCreationParams(
        params: platform is AndroidWebViewController
            ? AndroidWebViewWidgetCreationParams(
                controller: platform,
                displayWithHybridComposition: true,
              )
            : PlatformWebViewWidgetCreationParams(controller: platform),
      ),
    );
  }
}
