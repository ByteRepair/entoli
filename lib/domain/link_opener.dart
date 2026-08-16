import "package:flutter/widgets.dart";

/// Opens a link from rendered markdown. Android shows `http`/`https` in an
/// in-app webview; everything else (and every other platform) hands the URL to
/// the external browser.
abstract interface class LinkOpener {
  Future<void> open(BuildContext context, Uri url);
}