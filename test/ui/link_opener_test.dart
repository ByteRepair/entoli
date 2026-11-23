import "package:agent_chat/ui/link_opener.dart";
import "package:entoli_core/view/web_view.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late _FakeWebView webView;

  setUp(() => webView = _FakeWebView());

  /// The in-app webview is Android's alone, and the override has to be undone
  /// inside the body: flutter_test checks it before a tear-down runs.
  void androidTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  late TestApp app;
  tearDown(() => app.dispose());

  /// Opens [url] in the in-app browser, and hands back what gets copied out of
  /// it.
  Future<List<String>> openLink(WidgetTester tester, String url) async {
    final copied = clipboard(tester);
    app = TestApp.create();
    await app.pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => PlatformLinkOpener(
              FakeChatStore(),
              FakeLinkLauncher(),
              webView,
            ).open(context, Uri.parse(url)),
            child: const Text("open"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await settleIo(tester);
    return copied;
  }

  Future<void> tapCopyLink(WidgetTester tester) async {
    await tester.tap(find.byTooltip("Copy link"));
    await settleIo(tester);
  }

  androidTest("copies the page navigated to, not the link that opened it", (
    tester,
  ) async {
    final copied = await openLink(tester, "https://example.com/one");
    webView.onNavigated!(Uri.parse("https://example.com/two"), "Two");
    await settleIo(tester);

    await tapCopyLink(tester);

    expect(copied, ["https://example.com/two"]);
    expect(find.text("Copied link"), findsOneWidget);
    expect(find.text("Two"), findsOneWidget);
    expect(find.byTooltip("Open in browser"), findsOneWidget);
  });

  androidTest("nothing loaded yet copies the link it was opened with", (
    tester,
  ) async {
    final copied = await openLink(tester, "https://example.com/one");
    expect(webView.url, Uri.parse("https://example.com/one"));

    await tapCopyLink(tester);

    expect(copied, ["https://example.com/one"]);
  });

  test("only web, mail and phone links leave the app", () {
    expect(isOpenableLink(Uri.parse("https://example.com/")), isTrue);
    expect(isOpenableLink(Uri.parse("HTTP://example.com/")), isTrue);
    expect(isOpenableLink(Uri.parse("mailto:a@b.c")), isTrue);
    expect(isOpenableLink(Uri.parse("file:///etc/passwd")), isFalse);
    expect(isOpenableLink(Uri.parse("javascript:alert(1)")), isFalse);
  });
}

/// A [WebView] that loads nothing, keeping the [url] it was asked for and the
/// page's [onNavigated] for the test to fire by hand.
class _FakeWebView implements WebView {
  Uri? url;
  void Function(Uri url, String? title)? onNavigated;

  @override
  Widget view({
    required Uri url,
    void Function(Uri url, String? title)? onNavigated,
  }) {
    this.url = url;
    this.onNavigated = onNavigated;
    return const SizedBox.expand();
  }
}
