import "dart:typed_data";

/// A file on its way into a workspace from outside Entoli: picked in a
/// browser's chooser, or shared to the app by another one.
class IncomingFile {
  const IncomingFile({required this.path, required this.bytes});

  /// Where it lands, relative to the folder it is written into. A folder upload
  /// keeps its shape by naming `notes/today.md` rather than `today.md`, so this
  /// is a path and not a filename — and it comes from outside, so it goes
  /// through `safeRelativePath` before it is joined onto anything.
  final String path;

  final Uint8List bytes;
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
