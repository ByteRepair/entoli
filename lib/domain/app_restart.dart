/// Building the app again from what is on disk, optionally doing something to
/// the data directory first with no session alive over it. Restoring a backup
/// needs both halves — see AGENTS.md, "Backing it all up". Unticking the
/// licence needs only the second, to stop whatever the session was running.
abstract interface class AppRestart {
  /// Stop the app, run [whileStopped] if there is any, and start it again. With
  /// nothing to run the old session is kept on screen until the new one is
  /// ready; with something, it is stopped first, because that is the point.
  Future<void> restart({Future<void> Function()? whileStopped});
}
