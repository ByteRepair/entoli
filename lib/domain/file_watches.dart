import "dart:async";

import "trigger.dart" show FileEvent;

/// The file system's own push: the platform's directory watcher, behind a
/// port so the file kind of trigger cannot know which API it is being read
/// from — `dart:io`'s, and the rest behind it is the test's to stand in for.
///
/// Everything a watch is asked for is an *event under a root*, not a stream
/// per path: one watcher per directory tree, matched against the triggers in
/// it, is what keeps a fan of triggers over the same workspace from being a
/// fan of inotify subscriptions.
abstract interface class FileWatches {
  /// Events under [root], recursively. Never completes; cancelled when the
  /// kind's watch is torn down. A root that does not exist is not an error:
  /// the stream stays silent until the next registration builds the
  /// watcher for a root that does.
  Stream<FileWatchEvent> watch(String root);
}

/// One change the file system pushed, in [FileEvent]'s vocabulary — the
/// platform's own shapes translated at the edge (the one watch impl), so
/// nothing inside matches by string names.
class FileWatchEvent {
  const FileWatchEvent({required this.path, required this.kind});

  /// The path the event names, however the platform words it.
  final String path;

  /// The change. One wording, matching a trigger's own [FileSource.events]
  /// directly.
  final FileEvent kind;
}
