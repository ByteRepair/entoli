import "package:agent_chat/ui/link_opener.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late _FakeWebViewPlatform platform;

  setUp(() {
    platform = _FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  /// The in-app webview is Android's alone, and the override has to be undone
  /// inside the body: flutter_test checks it before a tear-down runs.
  void androidTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  /// Opens [url] in the in-app browser, and hands back what gets copied out of
  /// it.
  Future<List<String>> openLink(WidgetTester tester, String url) async {
    final copied = clipboard(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => PlatformLinkOpener(FakeChatStore()).open(context, Uri.parse(url)),
            child: const Text("open"),
          ),
        ),
      ),
    ));
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
    return copied;
  }

  Future<void> tapCopyLink(WidgetTester tester) async {
    await tester.tap(find.byTooltip("Copy link"));
    await tester.pumpAndSettle();
  }

  androidTest("copies the page navigated to, not the link that opened it", (tester) async {
    final copied = await openLink(tester, "https://example.com/one");
    platform.title = "Two";
    platform.delegate!.onPageFinished!("https://example.com/two");
    await tester.pumpAndSettle();

    await tapCopyLink(tester);

    expect(copied, ["https://example.com/two"]);
    expect(find.text("Copied link"), findsOneWidget);
    expect(find.text("Two"), findsOneWidget);
  });

  androidTest("a page that only rewrites its URL is still copied as it is", (tester) async {
    final copied = await openLink(tester, "https://example.com/one");
    platform.delegate!.onUrlChange!(const UrlChange(url: "https://example.com/three"));
    await tester.pumpAndSettle();

    await tapCopyLink(tester);

    expect(copied, ["https://example.com/three"]);
  });

  androidTest("nothing loaded yet copies the link it was opened with", (tester) async {
    final copied = await openLink(tester, "https://example.com/one");

    await tapCopyLink(tester);

    expect(copied, ["https://example.com/one"]);
  });
}

/// The webview, faked at the platform interface — see `test/CLAUDE.md` for why
/// here. Only the members the page calls are answered: the rest of the
/// interface keeps its default of throwing, so a new call shows up as a failure
/// rather than as a silent no-op.
class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeNavigationDelegate? delegate;
  String? title;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      _FakeWebViewController(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
          PlatformNavigationDelegateCreationParams params) =>
      delegate = _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
          PlatformWebViewWidgetCreationParams params) =>
      _FakeWebViewWidget(params);
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(super.params, this._platform) : super.implementation();

  final _FakeWebViewPlatform _platform;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}

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
