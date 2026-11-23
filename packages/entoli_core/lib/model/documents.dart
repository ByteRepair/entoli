import "dart:convert";

import "package:file/file.dart";

import "file_errors.dart";

/// What a document being written through a rename is called until the rename.
/// Whoever writes one spells it, and a backup skips one — it is the half of a
/// rename a kill landed in, not a file anything reads.
const writingSuffix = ".writing";

/// The one writer of a path: whole-file writes no reader may catch mid-way —
/// to the [writingSuffix] sibling, then a rename — queued per path, so two
/// overlapping saves land in the order they were asked and the disk ends on
/// the last — the copy the next read answers with. Each owner instantiates
/// its own and writes only its own paths through it; that one-writer rule is
/// what makes the fixed temp name safe, where two writers would rename the
/// same temp away from under each other. The caller that owns the parent
/// directory creates it.
///
/// The rename itself is what protects readers of the file — one sees the
/// whole old file or the whole new one, with no coordination to forget — so
/// there is no lock here for them, and none wanted where the reads are the
/// in-memory copy [Documents] serves.
///
/// [RenameWriter.over] runs a given write in place of the rename, so queue
/// behavior needs no filesystem at all.
class RenameWriter {
  RenameWriter(FileSystem fs) : _writeOne = _throughRename(fs);

  RenameWriter.over(this._writeOne);

  final Future<void> Function(String path, List<int> bytes) _writeOne;

  static Future<void> Function(String, List<int>) _throughRename(
    FileSystem fs,
  ) => (path, bytes) async {
    final temp = fs.file("$path$writingSuffix");
    await temp.writeAsBytes(bytes);
    await temp.rename(path);
  };

  /// One write per path at a time. Taken out once it is the tail: a write
  /// landing behind it queues behind it, and a clean finish leaves the map
  /// empty.
  final Map<String, Future<void>> _writes = {};

  /// How many paths still hold a queue entry — the drain the test pins.
  int get pendingWrites => _writes.length;

  Future<void> write(String path, String text) =>
      writeBytes(path, utf8.encode(text));

  Future<void> writeBytes(String path, List<int> bytes) {
    final queued = _writes[path];
    final write = queued == null
        ? _writeOne(path, bytes)
        : queued.then((_) => _writeOne(path, bytes));
    // The catch is what keeps a failed write's queue entry from being an
    // unhandled error beside the one the await delivers — the entry has
    // nowhere else to carry it to. The entry is the wrapper itself: every
    // combinator here (`catchError`, `whenComplete`) returns a fresh future,
    // so storing anything else and comparing against it never matches and
    // the path never drains.
    final tracked = write.catchError((_) {});
    _writes[path] = tracked;
    tracked.whenComplete(() {
      if (identical(_writes[path], tracked)) _writes.remove(path);
    });
    return write;
  }
}

/// The two JSON documents that are read synchronously: `settings.json` and each
/// project's `project.json`. Everything else on the filesystem is read as it is
/// needed.
///
/// These are not, because they are read on every command (`LocalShell` asks for
/// the environment per run) and on every model call (`LlmRegistry` asks for the
/// providers per client), so each is read off the disk the first time it is
/// asked for and served from memory after that — a project nobody opens is
/// never read at all.
///
/// The cost is that a file edited behind the app's back after its first read
/// is not picked up until a restart. Everything the app itself writes goes
/// through [write], which updates the copy before it touches the filesystem,
/// so a read on the next line sees it.
class Documents {
  Documents(this._fs) : _writes = RenameWriter(_fs);

  final FileSystem _fs;

  final RenameWriter _writes;

  /// Null for a file that was not there when it was first asked for.
  final Map<String, String?> _texts = {};

  /// Null where nothing has been written, which is the caller's cue to use its
  /// defaults rather than an error.
  String? read(String path) => _texts.putIfAbsent(path, () {
    try {
      return _fs.file(path).readAsStringSync();
    } on FileSystemException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  });

  /// Written through a rename for the same reason the chat store is:
  /// `writeAsString` truncates before it writes, so a read landing between the
  /// two finds an empty file. The copy is updated first, so a read on the next
  /// line sees the new value whatever the filesystem is still doing.
  Future<void> write(String path, String text) {
    _texts[path] = text;
    return _writes.write(path, text);
  }
}
