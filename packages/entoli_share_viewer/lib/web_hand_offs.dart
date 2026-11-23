import "dart:async";
import "dart:convert";
import "dart:js_interop";

import "package:entoli_chat/domain/chat_store.dart";
import "package:entoli_chat/domain/file_handoff.dart";
import "package:entoli_chat/domain/link_opener.dart";
import "package:file/file.dart";
import "package:flutter/widgets.dart";
import "package:path/path.dart" as p;
import "package:url_launcher/url_launcher.dart";
import "package:web/web.dart" as web;

/// A shared workspace's way out of the page: a file is downloaded, the one
/// thing a browser does with a file it is handed. There is no file manager
/// and no share sheet, and nothing is shared into a read-only chat.
class WebFileHandoff implements FileHandoff {
  const WebFileHandoff(this.fs);

  final FileSystem fs;

  @override
  Future<void> open(String path) async {
    final bytes = await fs.file(path).readAsBytes();
    final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS));
    (web.HTMLAnchorElement()
          ..href = url
          ..download = p.basename(path))
        .click();
    // Not at once: a browser may still be starting the download.
    Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
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
  const WebLinkOpener(this.fs, this.store);

  final FileSystem fs;
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
    final file = fs.file(p.join(dir, entryFile));
    if (!file.existsSync()) return;
    final html = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    final tab = web.window.open("", "_blank");
    if (tab == null) return;
    // A stranger's page, so in a sandboxed frame with an origin of its own: a
    // blob of it would run as this origin, with this tab as its opener.
    tab.opener = null;
    final doc = tab.document;
    doc.title = title ?? "Artifact";
    final frame = doc.createElement("iframe") as web.HTMLIFrameElement
      ..setAttribute(
        "sandbox",
        "allow-scripts allow-forms allow-modals allow-popups allow-downloads",
      )
      ..srcdoc = html.toJS;
    frame.style.cssText =
        "position:fixed;inset:0;width:100%;height:100%;border:0";
    (doc.body ?? doc.documentElement)?.append(frame);
  }
}
