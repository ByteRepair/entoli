import "package:flutter/widgets.dart";

/// The platform's web view, which a link and a phone's artifact open in.
abstract interface class WebView {
  /// [url] with scripts on; back goes back through the page's own history
  /// before it leaves. [onNavigated] hears each place the page lands, a
  /// rewritten address included, and that page's title.
  Widget view({
    required Uri url,
    void Function(Uri url, String? title)? onNavigated,
  });
}
