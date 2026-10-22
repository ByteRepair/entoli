import "dart:js_interop";
import "dart:js_interop_unsafe";

import "package:flutter/services.dart";
import "package:web/web.dart" as web;

import "../../log.dart";

/// See the io version. `clipboard.write` wants the user's gesture, which a
/// copy has: nothing is awaited before the call, so it is still inside the
/// key or tap that asked for it.
Future<void> setRichClipboard({required String plain, required String html}) async {
  try {
    final items = JSObject()
      ..setProperty("text/html".toJS, _blob(html, "text/html"))
      ..setProperty("text/plain".toJS, _blob(plain, "text/plain"));
    await web.window.navigator.clipboard.write([web.ClipboardItem(items)].toJS).toDart;
    return;
  } catch (e) {
    logFailure("clipboard", "rich copy refused, copying text", e);
  }
  await Clipboard.setData(ClipboardData(text: plain));
}

web.Blob _blob(String text, String type) =>
    web.Blob([text.toJS].toJS, web.BlobPropertyBag(type: type));
