import "package:path/path.dart" as p;

/// Turns write permission over a tree off ([writable] false) or back on for
/// the owner, files and directories alike. [executable] gives every file its
/// execute bit on the way to read-only. A no-op where there are no
/// permissions to set, as on the web.
typedef SetTreeWritable = Future<void> Function(List<String> paths,
    {required bool writable, bool executable});

/// A directory the app writes and the agent only reads: a chat's attachments,
/// the skills. Read-only on disk between the app's own writes, so a command
/// cannot change what the conversation holds by accident. A deliberate
/// `chmod` still can on the machine itself; the guests are patched not to.
class ReadOnlyDir {
  ReadOnlyDir._(this.path, this._set, {required this.executable});

  final String path;

  /// Whether files keep an execute bit while locked: a skill's scripts run,
  /// an attachment does not.
  final bool executable;

  final SetTreeWritable _set;

  /// The tail of this directory's writes, so one waits for the last: two
  /// overlapping would have the first relock under the second.
  Future<void> _last = Future.value();

  /// Runs [write] with the directory writable, and locks it after, whatever
  /// [write] did.
  Future<T> write<T>(Future<T> Function() write) {
    final run = _last.then((_) async {
      await _set([path], writable: true);
      try {
        return await write();
      } finally {
        await lock();
      }
    });
    _last = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Read-only now, without a write: for a directory made or filled before
  /// it was managed.
  Future<void> lock() => _set([path], writable: false, executable: executable);
}

/// One [ReadOnlyDir] per path, which is what serialises a path's writes:
/// two instances over one directory could not see each other's.
class ReadOnlyDirs {
  ReadOnlyDirs(this._set);

  /// Where there are no permissions to set, as on the web: every write goes
  /// straight through.
  ReadOnlyDirs.none() : _set = _none;

  static Future<void> _none(List<String> paths,
      {required bool writable, bool executable = false}) async {}

  final SetTreeWritable _set;
  final _dirs = <String, ReadOnlyDir>{};

  ReadOnlyDir of(String path, {bool executable = false}) =>
      _dirs.putIfAbsent(p.normalize(path),
          () => ReadOnlyDir._(p.normalize(path), _set, executable: executable));

  /// A skills directory: its files keep their execute bit, since a skill's
  /// scripts arrive from embedded data with none.
  ReadOnlyDir skills(String path) => of(path, executable: true);
}
