import "dart:io";

import "shell.dart" show pathsOverlap;

/// Why a folder cannot be a project's work folder — one of the
/// `writableDirs` a project grants every turn up front. The same two shapes
/// `add_directory` refuses before its banner.
enum WorkFolderRefusal {
  /// The app's own data tree: the data directory, anything under it, or
  /// anything holding it, which would make the app's settings, secrets and
  /// chats writable from inside its own permit.
  appData,

  /// Nothing, or a file, where a directory was asked for.
  notADirectory;

  String get message => switch (this) {
    appData => "That folder holds the app's own data, so it cannot be granted.",
    notADirectory => "That is not a folder on this device.",
  };
}

/// Why [path] cannot be added as a work folder, or null where it can.
WorkFolderRefusal? refuseWorkFolder(String path, {required String dataDir}) {
  if (pathsOverlap(path, dataDir)) return WorkFolderRefusal.appData;
  if (!FileSystemEntity.isDirectorySync(path)) {
    return WorkFolderRefusal.notADirectory;
  }
  return null;
}

/// Whether [path], a writable directory a tier persisted, grants anything to
/// the turn reading it now. A folder that is not on this machine — moved,
/// deleted, or synced here from another — grants nothing, so a command cannot
/// make it again under the grant; and nothing over the app's own data does,
/// whoever wrote it there. A `~` path stands: the gate resolves it, in a
/// guest's terms or the host's, and only then is there a folder to look for.
bool grantsNow(String path, {required String dataDir}) {
  if (path == "~" || path.startsWith("~/")) return true;
  return FileSystemEntity.isDirectorySync(path) && !pathsOverlap(path, dataDir);
}
