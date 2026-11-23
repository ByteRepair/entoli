import "package:entoli_webview/entoli_webview.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart";

void main() {
  late _FakeWebViewPlatform platform;

  setUp(() {
    platform = _FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  /// Shows https://example.com/one and hands back each place it said it
  /// landed.
  Future<List<(Uri, String?)>> show(WidgetTester tester) async {
    final heard = <(Uri, String?)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const PluginWebView().view(
            url: Uri.parse("https://example.com/one"),
            onNavigated: (url, title) => heard.add((url, title)),
          ),
        ),
      ),
    );
    return heard;
  }

  testWidgets("loads the URL it was given", (tester) async {
    await show(tester);
    expect(platform.loaded, [Uri.parse("https://example.com/one")]);
  });

  testWidgets("a finished page is said with its title", (tester) async {
    final heard = await show(tester);
    platform.title = "Two";
    platform.delegate!.onPageFinished!("https://example.com/two");
    await tester.pump();

    expect(heard, [(Uri.parse("https://example.com/two"), "Two")]);
  });

  testWidgets("a page that only rewrites its URL is somewhere new", (
    tester,
  ) async {
    final heard = await show(tester);
    platform.delegate!.onUrlChange!(
      const UrlChange(url: "https://example.com/three"),
    );
    await tester.pump();

    expect(heard, [(Uri.parse("https://example.com/three"), null)]);
  });
}

/// The web view, faked at the platform interface: `webview_flutter` has no
/// implementation on a test host. Only the members the view calls are
/// answered; the rest keep their default of throwing, so a new call shows up
/// as a failure rather than as a silent no-op.
class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeNavigationDelegate? delegate;
  String? title;
  final loaded = <Uri>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakeWebViewController(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => delegate = _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(super.params, this._platform) : super.implementation();

  final _FakeWebViewPlatform _platform;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _platform.loaded.add(params.uri);
  }

  @override
  Future<String?> getTitle() async => _platform.title;

  @override
  Future<bool> canGoBack() async => false;
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  PageEventCallback? onPageFinished;
  UrlChangeCallback? onUrlChange;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {
    this.onUrlChange = onUrlChange;
  }
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
