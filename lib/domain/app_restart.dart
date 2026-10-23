/// Building the app again from what is on disk, optionally doing something to
/// the data directory first with no session alive over it. Restoring a backup
/// is the only caller and needs both halves — see AGENTS.md, "Backing it all
/// up".
abstract interface class AppRestart {
  /// Stop the app, run [whileStopped] if there is any, and start it again. With
  /// nothing to run the old session is kept on screen until the new one is
  /// ready; with something, it is stopped first, because that is the point.
  Future<void> restart({Future<void> Function()? whileStopped});
}
