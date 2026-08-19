/// Asks the platform not to kill the app while there is work it must not lose.
/// Android's foreground services; a no-op everywhere else, where a process
/// nobody is looking at is left alone.
///
/// Nothing about the work moves. It runs in the isolate it always ran in; this
/// only buys that isolate the right to keep running off screen, and offers the
/// user a way to stop it from outside the app.
library;

/// What the process is being held open for. Three, because they are three
/// different things to stop — and because Android insists the one holding the
/// microphone be a service of a different type from the two that are not.
enum BackgroundJob { turns, voice, download }

/// A download worth telling the user about. Unlike the other two, its wording
/// cannot live in Kotlin: which model is being fetched is the catalog's.
class DownloadNotice {
  const DownloadNotice({
    required this.label,
    required this.received,
    required this.total,
  });

  final String label;
  final int received;
  final int total;
}

abstract interface class BackgroundWork {
  /// How many turns are running. Zero releases whatever was held.
  Future<void> running(int turns);

  /// Whether voice mode has the microphone open.
  Future<void> listening(bool active);

  /// The download under way, or null when there is none.
  Future<void> downloading(DownloadNotice? notice);

  /// The user said stop from outside the app — each notification has a button,
  /// and this says which was pressed. Whoever owns that kind of work stops it,
  /// which is what then takes the notification away: the button asks, it does
  /// not act.
  Stream<BackgroundJob> get stopRequests;
}
