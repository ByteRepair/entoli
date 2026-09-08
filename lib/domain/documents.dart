import "package:fs_shim/fs.dart";
import "package:uuid/uuid.dart";

/// What a document being written through a rename is called until the rename.
/// Whoever writes one spells it, and a backup skips one — it is the half of a
/// rename a kill landed in, not a file anything reads.
const writingSuffix = ".writing";

/// A whole-file write no reader may catch mid-way: to a temp sibling of
/// [path], then a rename. The temp name is unique to the write, so two
/// overlapping writers cannot rename the same file away from under each
/// other — a fixed name made the second rename fail ENOENT the moment the
/// first had taken it. The suffix stays the final segment, which is what the
/// backup's skip reads. The caller that owns the parent directory creates it.
Future<void> writeThroughRename(FileSystem fs, String path, String text) async {
  final temp = fs.file("$path.${const Uuid().v4()}$writingSuffix");
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

  /// One write per path at a time, so two overlapping saves land in the
  /// order they were asked: the disk ends on the last, which is the copy
  /// the next read answers with.
  final Map<String, Future<void>> _writes = {};

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
    final queued = _writes[path];
    final write = queued == null
        ? writeThroughRename(_fs, path, text)
        : queued.then((_) => writeThroughRename(_fs, path, text));
    // Taken out once it is the tail: a write landing behind it queues behind
    // it, and a clean finish leaves the map empty. The catch is what keeps a
    // failed write's queue entry from being an unhandled error beside the one
    // the await delivers — the entry has nowhere else to carry it to.
    _writes[path] = write.catchError((_) {}).whenComplete(() {
      if (identical(_writes[path], write)) _writes.remove(path);
    });
    await write;
  }
}
