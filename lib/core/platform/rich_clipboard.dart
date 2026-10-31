/// The clipboard with formatting. Flutter's `Clipboard` writes plain text and
/// nothing else, all the way down to each embedder, so a word processor
/// pasting from it gets no formatting; this writes an HTML entry beside the
/// text through the runner's channel, and plain text wherever it does not
/// answer.
library;

import "package:flutter/services.dart";

import "../log.dart";

/// One copy: [plain] for a target that reads text, and [html] — a whole
/// document, as `htmlClipboardDocument` makes one — for one that keeps
/// formatting. A paste takes whichever it reads.
class ClipboardContent {
  const ClipboardContent({required this.plain, this.html});

  final String plain;
  final String? html;
}

const _channel = MethodChannel("agent_chat/clipboard");

/// Put [content] on the clipboard: both entries through `agent_chat/clipboard`
/// where the runner answers it, the text alone through Flutter's where it
/// does not.
Future<void> writeClipboard(ClipboardContent content) async {
  final html = content.html;
  if (html != null) {
    try {
      await _channel.invokeMethod<void>("setHtml", {
        "plain": content.plain,
        "html": html,
      });
      return;
    } on MissingPluginException catch (_) {
      // A runner without the channel, and the tests: the text is still a
      // copy.
    } on PlatformException catch (e) {
      logFailure("clipboard", "rich copy refused, copying text", e);
    }
  }
  await Clipboard.setData(ClipboardData(text: content.plain));
}
