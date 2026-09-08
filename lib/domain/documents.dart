import "package:fs_shim/fs.dart";

/// What a document being written through a rename is called until the rename.
/// Whoever writes one spells it, and a backup skips one — it is the half of a
/// rename a kill landed in, not a file anything reads.
const writingSuffix = ".writing";

/// A whole-file write no reader may catch mid-way: to the [writingSuffix]
/// sibling, then a rename. The caller that owns the parent directory creates
/// it.
Future<void> writeThroughRename(FileSystem fs, String path, String text) async {
  final temp = fs.file("$path$writingSuffix");
  await temp.writeAsString(text);
  await temp.rename(path);
}

/// The two JSON documents that are read synchronously: `settings.json` and each
/// project's `project.json`. Everything else on the filesystem is read as it is
/// needed.
///
/// These are not, because they are read on every command (`LocalShell` asks for
/// the environment per run) and on every model call (`LlmRegistry` asks for the
/// providers per client). The filesystem is async — a browser's has to be — so
/// they are read once at startup and served from memory after that.
///
/// The cost is that a file edited behind the app's back is not picked up until
/// a restart. Everything the app itself writes goes through [write], which
/// updates the copy before it touches the filesystem, so a read on the next
/// line sees it.
class Documents {
  Documents(this._fs);

  final FileSystem _fs;
  final Map<String, String> _texts = {};

  Future<void> hydrate(Iterable<String> paths) async {
    for (final path in paths) {
      final file = _fs.file(path);
      if (await file.exists()) _texts[path] = await file.readAsString();
    }
  }

  /// Null where nothing has been written, which is the caller's cue to use its
  /// defaults rather than an error.
  String? read(String path) => _texts[path];

  /// Written through a rename for the same reason the chat store is:
  /// `writeAsString` truncates before it writes, so a read landing between the
  /// two finds an empty file. The copy is updated first, so a read on the next
  /// line sees the new value whatever the filesystem is still doing.
  Future<void> write(String path, String text) async {
    _texts[path] = text;
    await writeThroughRename(_fs, path, text);
  }
}
