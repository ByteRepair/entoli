/// Asks the platform not to kill the app while a turn is running. Android's
/// foreground service; a no-op everywhere else, where a process nobody is
/// looking at is left alone.
///
/// Nothing about the turn moves. It runs in the isolate it always ran in; this
/// only buys that isolate the right to keep running off screen, and offers the
/// user a way to stop it from outside the app.
abstract interface class BackgroundWork {
  /// How many turns are running. Zero releases whatever was held.
  Future<void> running(int turns);

  /// The user said stop from outside the app — Android's notification has a
  /// button. Every running turn is aborted, which is what then brings [running]
  /// back to zero.
  Stream<void> get stopRequests;
}
