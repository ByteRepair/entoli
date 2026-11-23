import "dart:io";
import "dart:js_interop";

import "package:entoli_chat/domain/chat_store.dart";
import "package:entoli_chat/domain/file_handoff.dart";
import "package:entoli_chat/domain/link_opener.dart";
import "package:flutter/widgets.dart";
import "package:path/path.dart" as p;
import "package:url_launcher/url_launcher.dart";
import "package:web/web.dart" as web;

/// A shared workspace's way out of the page: a file is downloaded, the one
/// thing a browser does with a file it is handed. There is no file manager
/// and no share sheet, and nothing is shared into a read-only chat.
class WebFileHandoff implements FileHandoff {
  const WebFileHandoff();

  @override
  Future<void> open(String path) async {
    final bytes = await File(path).readAsBytes();
    final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS));
    (web.HTMLAnchorElement()
          ..href = url
          ..download = p.basename(path))
        .click();
    web.URL.revokeObjectURL(url);
  }

  @override
  String? get fileManager => null;

  @override
  Future<void> reveal(String dir) async {}

  @override
  bool get canShare => false;

  @override
  Future<void> export(List<String> paths) async {
    for (final path in paths) {
      await open(path);
    }
  }

  @override
  Future<List<IncomingFile>> takeShare() async => const [];

  @override
  Stream<void> get shareArrived => const Stream.empty();
}

/// A link in a stranger's chat: a web page opens in a tab of its own, and
/// anything else a model wrote is not followed. An artifact's page opens in
/// a tab as it was published; a file beside it that the page names does not
/// come with it, which the app's opener serves.
class WebLinkOpener implements LinkOpener {
  const WebLinkOpener(this.store);

  final ChatStore store;

  @override
  Future<void> open(BuildContext context, Uri url) async {
    if (url.scheme != "https" && url.scheme != "http") return;
    await launchUrl(url, webOnlyWindowName: "_blank");
  }

  @override
  Future<void> openSignIn(BuildContext context, Uri url) => open(context, url);

  @override
  Future<void> openArtifact(
    BuildContext context,
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) async {
    final dir = await store.artifactPath(chatId, artifactId);
    final file = File(p.join(dir, entryFile));
    if (!file.existsSync()) return;
    final bytes = await file.readAsBytes();
    final url = web.URL.createObjectURL(
      web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: "text/html")),
    );
    web.window.open(url, "_blank");
  }
}
