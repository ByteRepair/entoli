import "dart:async";
import "dart:io" as io;

import "../../domain/file_watches.dart";

/// The machine's watcher: `dart:io`'s `Directory.watch`, recursive — the
/// file tools read workspaces whole, and a trigger over `project:notes/`
/// means everything under it.
class IoFileWatches implements FileWatches {
  const IoFileWatches();

  @override
  bool get available => true;

  @override
  Stream<FileWatchEvent> watch(String root) {
    final directory = io.Directory(root);
    if (!directory.existsSync()) return const Stream.empty();
    Stream<io.FileSystemEvent> events;
    try {
      events = directory.watch(recursive: true);
    } catch (_) {
      // Some file systems refuse a recursive watch; a non-recursive one
      // over the root still catches the root's own entries.
      try {
        events = directory.watch();
      } catch (_) {
        return const Stream.empty();
      }
    }
    return events
        .where((event) => event.path.isNotEmpty)
        .map((io.FileSystemEvent event) {
          final kind = event is io.FileSystemDeleteEvent
              ? FileEventKind.delete
              : event is io.FileSystemMoveEvent
                  ? FileEventKind.move
                  : event is io.FileSystemCreateEvent
                      ? FileEventKind.create
                      : FileEventKind.modify;
          return FileWatchEvent(path: event.path, kind: kind);
        })
        .handleError((Object _) {
      // A watcher over a directory that has been removed since — a temp
      // workspace swept, a project deleted — is silence, not a crash: the
      // next registration rebuilds what the list still asks for.
    });
  }
}