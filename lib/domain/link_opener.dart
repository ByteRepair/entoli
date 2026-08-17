import "package:flutter/widgets.dart";

/// Opens a link from rendered markdown, and an artifact the model rendered.
/// Android shows `http`/`https` in an in-app webview; everything else (and
/// every other platform) hands the URL to the external browser. Artifacts open
/// the same way on Android and desktop; on web, a blob URL opens in a new tab.
abstract interface class LinkOpener {
  Future<void> open(BuildContext context, Uri url);

  /// Open the artifact [artifactId] saved under [chatId]. [entryFile] is the
  /// filename in the artifact dir the viewer should open. The title is for the
  /// app bar of the in-app viewer, where there is one.
  Future<void> openArtifact(
    BuildContext context,
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  });
}