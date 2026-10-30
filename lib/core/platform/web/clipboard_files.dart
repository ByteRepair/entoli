import "dart:async";
import "dart:js_interop";

import "package:web/web.dart" as web;

import "../../../data/mime.dart";
import "../../../domain/clipboard_files.dart";
import "../../../domain/models.dart";
import "../../log.dart";

ClipboardFiles createClipboardFiles() => DomClipboardFiles();

/// A browser's files reach a page on the paste event and nowhere else, and
/// Ctrl+V never reaches Flutter's shortcuts here: the browser pastes into the
/// engine's hidden field itself. So this listens on the document, and a paste
/// that carried files has its text, the file's name, stopped.
class DomClipboardFiles implements ClipboardFiles {
  DomClipboardFiles() {
    web.document.addEventListener("paste", _onPaste.toJS, true.toJS);
  }

  final _pasted = StreamController<List<Attachment>>.broadcast();

  @override
  Future<List<Attachment>> read() async => const [];

  @override
  Stream<List<Attachment>> get pasted => _pasted.stream;

  void _onPaste(web.ClipboardEvent event) {
    final files = event.clipboardData?.files;
    if (files == null || files.length == 0 || !_pasted.hasListener) return;
    event.preventDefault();
    final read = [for (var i = 0; i < files.length; i++) _read(files.item(i)!)];
    Future.wait(read).then(_pasted.add, onError: (Object e) {
      logFailure("clipboard", "reading pasted files failed", e);
    });
  }
}

Future<Attachment> _read(web.File file) async {
  final bytes = (await file.arrayBuffer().toDart).toDart.asUint8List();
  return pastedAttachment(bytes,
      name: file.name.isEmpty ? null : file.name,
      declared: file.type.isEmpty ? null : file.type);
}
