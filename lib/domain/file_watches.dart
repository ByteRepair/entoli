import "dart:async";

/// The file system's own push: the platform's directory watcher, behind a
/// port so the file kind of trigger cannot know which API it is being read
/// from — `dart:io`'s on the machine and Android, nothing in a browser, and
/// the rest behind it is the test's to stand in for.
///
/// Everything a watch is asked for is an *event under a root*, not a stream
/// per path: one watcher per directory tree, matched against the triggers in
/// it, is what keeps a fan of triggers over the same workspace from being a
/// fan of inotify subscriptions.
abstract interface class FileWatches {
  /// Whether this platform can watch at all. False in a browser — an
  /// IndexedDB file system has no inotify to carry — and wherever the app
  /// was built without the IO half.
  bool get available;

  /// Events under [root], recursively. Never completes; cancelled when the
  /// kind's watch is torn down. A root that does not exist is not an error:
  /// the stream stays silent until the next registration builds the
  /// watcher for a root that does.
  Stream<FileWatchEvent> watch(String root);
}

/// One change the file system pushed.
class FileWatchEvent {
  const FileWatchEvent({required this.path, required this.kind});

  /// The path the event names, however the platform words it.
  final String path;

  /// The change, in the kinds' small vocabulary.
  final FileEventKind kind;
}

enum FileEventKind { create, modify, delete, move }

/// Where nothing can watch: a browser, or the test that wants watch events
/// decided rather than observed.
class UnavailableFileWatches implements FileWatches {
  const UnavailableFileWatches();

  @override
  bool get available => false;

  @override
  Stream<FileWatchEvent> watch(String root) => const Stream.empty();
}