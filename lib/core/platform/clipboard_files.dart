/// Files on the clipboard, for the composer's paste: the runner's channel on
/// the platforms with one, the paste event in a browser.
library;

export "io/clipboard_files.dart" if (dart.library.js_interop) "web/clipboard_files.dart";
