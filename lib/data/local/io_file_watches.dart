import "dart:io" as io;

import "../../domain/file_watches.dart";
import "../../domain/trigger.dart" show FileEvent;

/// The machine's watcher: `dart:io`'s `Directory.watch`, recursive — the
/// file tools read workspaces whole, and a trigger over `project:notes/`
/// means everything under it. The platform's event shapes are translated to
/// [FileEvent] here and nowhere else.
class IoFileWatches implements FileWatches {
  const IoFileWatches();

  @override
  Stream<FileWatchEvent> watch(String root) {
    // A path may be a file — the build-log case the tool schema itself
    // suggests — and `Directory.watch` works over one on the platforms this
    // runs; only *nothing there* is silence (the port's own bargain: the
    // next registration rebuilds for a root that exists).
    if (io.FileSystemEntity.typeSync(root, followLinks: true) ==
        io.FileSystemEntityType.notFound) {
      return const Stream.empty();
    }
    Stream<io.FileSystemEvent> events;
    try {
      events = io.Directory(root).watch(recursive: true);
    } catch (_) {
      // Some file systems refuse a recursive watch; a non-recursive one
      // over the root still catches the root's own entries.
      try {
        events = io.Directory(root).watch();
      } catch (_) {
        return const Stream.empty();
      }
    }
    return events
        .where((event) => event.path.isNotEmpty)
        .map((io.FileSystemEvent event) => FileWatchEvent(
              path: event.path,
              kind: event is io.FileSystemDeleteEvent
                  ? FileEvent.delete
                  : event is io.FileSystemMoveEvent
                      ? FileEvent.move
                      : event is io.FileSystemCreateEvent
                          ? FileEvent.create
                          : FileEvent.change,
            ))
        .handleError((Object _) {
      // A watcher over a directory that has been removed since — a temp
      // workspace swept, a project deleted — is silence, not a crash: the
      // next registration rebuilds what the list still asks for.
    });
  }
}