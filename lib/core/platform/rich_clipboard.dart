/// The clipboard with formatting. Flutter's `Clipboard` writes plain text and
/// nothing else, all the way down to each embedder, so a word processor
/// pasting from it gets no formatting; this writes an HTML entry beside the
/// text through the runner's channel, and plain text wherever it does not
/// answer.
library;

import "package:flutter/services.dart";

import "../log.dart";

const _channel = MethodChannel("agent_chat/clipboard");

/// Put [plain] and [html] on the clipboard as one entry, a paste target
/// taking whichever it reads. [html] is a whole document, as
/// `htmlClipboardDocument` makes one.
Future<void> setRichClipboard({
  required String plain,
  required String html,
}) async {
  try {
    await _channel.invokeMethod<void>("setHtml", {
      "plain": plain,
      "html": html,
    });
    return;
  } on MissingPluginException catch (_) {
    // A runner without the channel, and the tests: the text is still a copy.
  } on PlatformException catch (e) {
    logFailure("clipboard", "rich copy refused, copying text", e);
  }
  await Clipboard.setData(ClipboardData(text: plain));
}
