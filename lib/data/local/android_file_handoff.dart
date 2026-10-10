import "dart:async";

import "package:flutter/services.dart";
import "package:fs_shim/fs.dart";
import "package:path_provider/path_provider.dart";

import "../../domain/file_handoff.dart";
import "../mime.dart";
import "../zip.dart";
import "../../core/log.dart";

/// Android, where every route runs through an intent and `FilesChannel.kt` is
/// the other end of `agent_chat/files`. There is no file manager to point at a
/// folder and no chooser of Entoli's own: files leave through the share sheet
/// and come back the same way, from another app sharing to Entoli.
///
/// Everything the channel is handed is a copy under the app's cache rather than
/// the workspace file itself, because a `FileProvider` only mints URIs under
/// the paths it is configured with and one cache directory is the whole of that
/// configuration. See AGENTS.md, "The workspace explorer".
class AndroidFileHandoff implements FileHandoff {
  AndroidFileHandoff(this._fs) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel("agent_chat/files");

  final FileSystem _fs;
  final _arrived = StreamController<void>.broadcast();

  /// Asked once. `path_provider` sends a platform message per call, and this is
  /// in front of every file the user taps.
  late final Future<String> _cache =
      getTemporaryDirectory().then((dir) => dir.path);

  @override
  bool get canReveal => false;

  @override
  ExportKind get exportKind => ExportKind.share;

  @override
  bool get canImport => false;

  @override
  Stream<void> get shareArrived => _arrived.stream;

  @override
  Future<void> reveal(String dir) async {}

  @override
  Future<List<IncomingFile>> import({required bool folders}) async => const [];

  @override
  Future<void> open(String path) async {
    final staged = await _stage([path]);
    await _invoke<void>("open", {"path": staged.single, "mime": viewerMime(staged.single)});
  }

  @override
  Future<void> export(List<String> paths) async {
    if (paths.isEmpty) return;
    final staged = await _stage(paths);
    await _invoke<void>("share", {
      "paths": staged,
      "mime": staged.length == 1 ? viewerMime(staged.single) : "*/*",
    });
  }

  /// The staged copies, named but not read. `FilesChannel` hands over the
  /// directory it put them in, and each one is moved out of it when a workspace
  /// is picked — so nothing here holds a share's bytes, and reading the queue
  /// still empties it.
  @override
  Future<List<IncomingFile>> takeShare() async {
    final staged = await _invoke<List<Object?>>("takeShare") ?? const [];
    return [
      for (final entry in staged.cast<Map<Object?, Object?>>())
        IncomingStaged(entry["path"]! as String, entry["file"]! as String),
    ];
  }

  /// The copies the share sheet and the viewer are handed. A folder becomes one
  /// zip, since an intent carries files; several files stay several, which is
  /// what `ACTION_SEND_MULTIPLE` is for. Two files of the same name cannot
  /// arrive here — a selection is one folder's, and siblings are unique.
  Future<List<String>> _stage(List<String> paths) async {
    final dir = await _emptyStagingDir();
    final folders = await Future.wait(paths.map(_fs.isDirectory));
    if (folders.contains(true)) {
      final zip = _fs.path.join(dir, zipNameFor(_fs, paths));
      await _fs.file(zip).writeAsBytes(await zipEntries(_fs, paths));
      return [zip];
    }
    return Future.wait(paths.map((path) async {
      final copy = _fs.path.join(dir, _fs.path.basename(path));
      await _fs.file(path).copy(copy);
      return copy;
    }));
  }

  /// Emptied rather than added to: what was staged last time has been read by
  /// whatever it was shared with, and nothing else would ever clear it.
  Future<String> _emptyStagingDir() async {
    final dir = _fs.path.join(await _cache, "shared");
    final directory = _fs.directory(dir);
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
    return dir;
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method == "shared") _arrived.add(null);
  }

  /// Logged rather than raised, the way `ForegroundService` does it: what the
  /// channel refuses is a share sheet that will not open, and the page says so.
  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      logFailure("files", "handing a file to the system failed", e);
    } on MissingPluginException catch (_) {}
    return null;
  }
}
