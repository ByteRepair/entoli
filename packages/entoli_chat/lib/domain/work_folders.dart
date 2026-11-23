import "dart:io";

import "package:path/path.dart" as p;

import "shell.dart" show isTildePath, pathInside, pathsOverlap;

/// Why a folder cannot be granted for writing outside the workspaces —
/// whether as a project's work folder, up front, or by an `add_directory`
/// banner. One list for both doors, since what either opens is the same
/// sandbox grant.
enum FolderRefusal {
  /// Nothing is there.
  missing,

  /// A file, where a directory was asked for.
  notADirectory,

  /// The filesystem's root, which holds everything.
  root,

  /// The machine user's home, or a folder holding it: every dotfile and
  /// every other project at once.
  home,

  /// The app's own data tree: the data directory, anything under it, or
  /// anything holding it, which would make the app's settings, secrets and
  /// chats writable from inside its own permit.
  appData,

  /// A folder holding the workspaces, which would hand the sandbox the
  /// tree they sit in.
  workspaces;

  /// What the settings page says when this folder is refused.
  String get message => switch (this) {
    missing || notADirectory => "That is not a folder on this device.",
    root => "The whole disk cannot be granted.",
    home => "Your home folder, or one holding it, cannot be granted.",
    appData => "That folder holds the app's own data, so it cannot be granted.",
    workspaces =>
      "That folder holds the project's workspace, which is "
          "already writable.",
  };

  /// What a work folder's row says under its path while this holds.
  String get row => switch (this) {
    missing || notADirectory => "Missing on this device",
    root => "The whole disk, so it grants nothing",
    home => "Your home folder or above it, so it grants nothing",
    appData => "Holds the app's own data, so it grants nothing",
    workspaces => "Holds the project's workspace, so it grants nothing",
  };
}

/// Why [dir] cannot be granted, or null where it can. [home] is the machine
/// user's, [dataDir] the app's (null in a test that does not reach it), and
/// [workspaces] the chat's and the project's.
FolderRefusal? refuseFolder(
  String dir, {
  required String? dataDir,
  required String? home,
  List<String> workspaces = const [],
}) {
  final type = FileSystemEntity.typeSync(dir);
  if (type == FileSystemEntityType.notFound) return FolderRefusal.missing;
  if (type != FileSystemEntityType.directory) {
    return FolderRefusal.notADirectory;
  }
  if (p.dirname(p.normalize(dir)) == p.normalize(dir)) {
    return FolderRefusal.root;
  }
  if (home != null && pathInside(home, dir)) return FolderRefusal.home;
  if (dataDir != null && pathsOverlap(dir, dataDir)) {
    return FolderRefusal.appData;
  }
  if (workspaces.any((w) => pathInside(w, dir))) {
    return FolderRefusal.workspaces;
  }
  return null;
}

/// Whether [path], a writable directory a tier persisted, grants anything to
/// the turn reading it: one [refuseFolder] refuses now — moved, deleted,
/// synced here from another machine, or over the app's data whoever wrote it
/// there — grants nothing, so a command cannot make it again under the
/// grant. A `~` path stands: the gate resolves it, in a guest's terms or the
/// host's, and only then is there a folder to look for.
bool grantsNow(
  String path, {
  required String? dataDir,
  required String? home,
  List<String> workspaces = const [],
}) =>
    isTildePath(path) ||
    refuseFolder(path, dataDir: dataDir, home: home, workspaces: workspaces) ==
        null;
