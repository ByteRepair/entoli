import "dart:async";
import "dart:js_interop";
import "dart:typed_data";

import "package:fs_shim/fs.dart";
import "package:web/web.dart" as web;

import "../../domain/file_handoff.dart";
import "../mime.dart";
import "../zip.dart";

/// A browser, where a workspace file is a row in IndexedDB rather than
/// something the operating system knows about. Opening one is a blob in a new
/// tab, which is what lets the browser preview it; taking one out is a
/// download; taking one in is the chooser `<input type="file">` already is.
class WebFileHandoff implements FileHandoff {
  WebFileHandoff(this._fs);

  final FileSystem _fs;

  @override
  bool get canReveal => false;

  @override
  ExportKind get exportKind => ExportKind.download;

  @override
  bool get canImport => true;

  /// Nothing shares to a tab. The stream is here so the app can listen without
  /// first asking which platform it is on.
  @override
  Stream<void> get shareArrived => const Stream.empty();

  @override
  Future<List<IncomingFile>> takeShare() async => const [];

  @override
  Future<void> reveal(String dir) async {}

  @override
  Future<void> open(String path) async {
    final url = _objectUrl(await _fs.file(path).readAsBytes(), viewerMime(path));
    web.window.open(url, "_blank");
  }

  @override
  Future<void> export(List<String> paths) async {
    if (paths.isEmpty) return;
    final single = paths.length == 1 && await _fs.isFile(paths.single);
    final name = single ? _fs.path.basename(paths.single) : zipNameFor(_fs, paths);
    final bytes = single ? await _fs.file(paths.single).readAsBytes() : await zipEntries(_fs, paths);
    final url = _objectUrl(bytes, single ? viewerMime(name) : "application/zip");
    final anchor = web.document.createElement("a") as web.HTMLAnchorElement
      ..href = url
      ..download = name;
    // In the document before the click: a detached anchor does nothing in
    // Firefox.
    web.document.body!.appendChild(anchor);
    anchor.click();
    anchor.remove();
  }

  @override
  Future<List<IncomingFile>> import({required bool folders}) {
    final input = web.document.createElement("input") as web.HTMLInputElement
      ..type = "file"
      ..multiple = true
      ..webkitdirectory = folders;

    final done = Completer<List<IncomingFile>>();
    // Block bodies, not arrows: a callback handed to `toJS` has to return void,
    // and an arrow would return the future `then` makes.
    input.addEventListener("change", ((web.Event _) {
      _read(input).then(done.complete, onError: done.completeError);
    }).toJS);
    // A cancelled chooser fires nothing else, and a future nobody completes is
    // a menu that never closes.
    input.addEventListener("cancel", ((web.Event _) {
      if (!done.isCompleted) done.complete(const []);
    }).toJS);
    input.click();
    return done.future;
  }

  Future<List<IncomingFile>> _read(web.HTMLInputElement input) async {
    final chosen = input.files;
    if (chosen == null) return const [];
    final files = <IncomingFile>[];
    for (var i = 0; i < chosen.length; i++) {
      final file = chosen.item(i)!;
      final buffer = (await file.arrayBuffer().toDart).toDart;
      files.add(IncomingFile(path: _pathOf(file), bytes: buffer.asUint8List()));
    }
    return files;
  }

  /// A folder upload names each file by its path under the folder that was
  /// picked, so the folder survives the round trip. A plain file upload leaves
  /// that empty and is only ever a name.
  String _pathOf(web.File file) =>
      file.webkitRelativePath.isEmpty ? file.name : file.webkitRelativePath;

  /// A blob is a whole copy of the file, so only one is ever held: the previous
  /// goes as the next is minted, and a timer catches the last. Not revoked the
  /// moment it is handed over — the tab or the download still has to fetch it,
  /// and revoking first cancels what was just asked for.
  String _objectUrl(Uint8List bytes, String mime) {
    _release();
    _held = web.URL.createObjectURL(
      web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mime)),
    );
    _trailing?.cancel();
    _trailing = Timer(const Duration(minutes: 1), _release);
    return _held!;
  }

  void _release() {
    final url = _held;
    if (url == null) return;
    _held = null;
    web.URL.revokeObjectURL(url);
  }

  String? _held;
  Timer? _trailing;
}
