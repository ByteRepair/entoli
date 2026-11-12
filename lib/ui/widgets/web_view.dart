import "package:flutter/material.dart";
import "package:webview_flutter/webview_flutter.dart";
import "package:webview_flutter_android/webview_flutter_android.dart";

import "../../app/settings/controller.dart";

/// A [WebController]'s page in the platform's web view, scripts on; back
/// goes back through the page's own history before it leaves.
class WebPageView extends StatefulWidget {
  const WebPageView(this.c, {super.key});

  final WebController c;

  @override
  State<WebPageView> createState() => _WebPageViewState();
}

class _WebPageViewState extends State<WebPageView> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) async {
          final back = await _controller.canGoBack();
          if (mounted && back != _canGoBack) setState(() => _canGoBack = back);
        },
      ),
    )
    ..loadRequest(widget.c.url);
  var _canGoBack = false;

  @override
  Widget build(BuildContext context) {
    final platform = _controller.platform;
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _canGoBack) await _controller.goBack();
      },
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
