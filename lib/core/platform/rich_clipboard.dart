/// The clipboard with formatting. Flutter's `Clipboard` writes plain text and
/// nothing else, all the way down to each embedder, so a word processor
/// pasting from it gets no formatting; this writes an HTML entry beside the
/// text. Native on the platforms with an app runner, `navigator.clipboard` in
/// a browser, and plain text wherever neither answers.
library;

export "io/rich_clipboard.dart" if (dart.library.js_interop) "web/rich_clipboard.dart";
