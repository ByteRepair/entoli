import "dart:typed_data";

import "package:fs_shim/fs.dart";

/// A file on its way into a workspace from outside Entoli: picked in a
/// browser's chooser, or shared to the app by another one.
///
/// Deliberately not the bytes — a batch waits on screen while a workspace is
/// picked, and holding it as buffers is what a phone gets killed for. Each
/// variant holds whatever its own source already had; [writeTo] is where that
/// becomes a file. See AGENTS.md, "The workspace explorer".
abstract class IncomingFile {
  const IncomingFile(this.path);

  /// Where it lands, relative to the folder it is written into. A folder upload
  /// keeps its shape by naming `notes/today.md` rather than `today.md`, so this
  /// is a path and not a filename — and it comes from outside, so it goes
  /// through `safeRelativePath` before it is joined onto anything.
  final String path;

  /// Put it at [target], which the caller has already made room for.
  ///
  /// Once, and it consumes what it was holding: a staged copy is moved out of
  /// where the platform put it, so a second call has nothing left to write.
  /// Whoever offers a retry has to offer it over files that have not landed
  /// yet, never over the same list again.
  Future<void> writeTo(FileSystem fs, String target);
}

/// Bytes already in hand, which is the one case with nothing to defer.
class IncomingBytes extends IncomingFile {
  const IncomingBytes(super.path, this.bytes);

  final Uint8List bytes;

  @override
  Future<void> writeTo(FileSystem fs, String target) =>
      fs.file(target).writeAsBytes(bytes);
}

/// A copy the platform staged on disk before Entoli was told about it —
/// Android's, under the app's cache, because the URI it was shared as is only
/// readable while the task that received it lives. Moved rather than read, and
/// the copy is the fallback for a device where that turns out to cross volumes.
class IncomingStaged extends IncomingFile {
  const IncomingStaged(super.path, this.staged);

  /// Where the platform put it. Consumed by [writeTo], which is also what
  /// stops an abandoned share being left behind twice.
  final String staged;

  @override
  Future<void> writeTo(FileSystem fs, String target) async {
    final file = fs.file(staged);
    try {
      await file.rename(target);
    } on FileSystemException catch (e) {
      // Only a rename across volumes is worth a second try. A copy of a file
      // that is not there fails the same way and buries the real cause under
      // its own.
      if (e.status == FileSystemException.statusNotFound) rethrow;
      await file.copy(target);
      await file.delete();
    }
  }
}

/// Which way out of the app a selection takes. The port answers with the kind
/// rather than the wording, so the button's name and its icon are decided in
/// one place and that place is the UI.
enum ExportKind { share, download }

/// What a workspace file can do outside Entoli, and what can come back in. Each
/// route is gated the way `Shell.canRunCommands` gates the agent's commands,
/// because the three platforms answer differently rather than partially:
///
/// - Desktop opens a file in the viewer it is registered with, and shows a
///   folder in the file manager. It has no share sheet and needs no chooser of
///   its own — the file manager is already pointed at the workspace.
/// - Android opens a file with an `ACTION_VIEW` intent, sends a selection out
///   through the share sheet, and takes files in the same way: another app
///   shares to Entoli, and [takeShare] is what is waiting when it does.
/// - A browser opens a file in a new tab and lets itself preview it, downloads
///   a selection, and takes files in through [import].
abstract interface class FileHandoff {
  /// Open [path] in whatever this platform views that kind of file with.
  Future<void> open(String path);

  /// Show [dir] in the platform's file manager.
  bool get canReveal;
  Future<void> reveal(String dir);

  /// Hand [paths] to the rest of the device. Neither destination takes a
  /// folder, so a selection with one in it goes as a single zip. Null is a
  /// platform with nowhere to hand them.
  ExportKind? get exportKind;
  Future<void> export(List<String> paths);

  /// Take files in through a chooser of Entoli's own. Only a browser has one:
  /// Android's route in is the share sheet, and desktop's is the file manager.
  bool get canImport;
  Future<List<IncomingFile>> import({required bool folders});

  /// What another app shared to Entoli and nothing has claimed yet. Reading it
  /// empties it, so one share is offered a workspace exactly once.
  Future<List<IncomingFile>> takeShare();

  /// A share arrived while the app was already up. The one read at startup
  /// covers the other case, where the share is what launched the app and Dart
  /// was not listening yet.
  Stream<void> get shareArrived;
}
