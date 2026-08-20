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

/// The one caller of [BackgroundWork.downloading].
///
/// Three catalogs fetch into one platform slot — a voice model, a Linux, and a
/// model to run on the device — and `downloading(null)` stops the foreground
/// service outright. So a four-megabyte rootfs finishing while a two-gigabyte
/// model is still streaming would drop the hold and leave the app killable in
/// the middle of the longest download it makes. Merging here makes that
/// unrepresentable rather than a rule each of the three has to keep.
class DownloadHold {
  DownloadHold(this._work);

  final BackgroundWork _work;

  /// By source, so a catalog only ever speaks for itself.
  final _notices = <String, DownloadNotice>{};

  /// What [source] is fetching, or null when it has stopped. Answering with the
  /// call so a caller that wants to wait can.
  Future<void> report(String source, DownloadNotice? notice) {
    if (notice == null) {
      _notices.remove(source);
    } else {
      _notices[source] = notice;
    }
    return _work.downloading(_merged);
  }

  DownloadNotice? get _merged {
    if (_notices.isEmpty) return null;
    return DownloadNotice(
      // One name where there is one, since "1 download" says less than the
      // thing being downloaded.
      label: _notices.length == 1
          ? _notices.values.single.label
          : "${_notices.length} downloads",
      received: _notices.values.fold(0, (sum, n) => sum + n.received),
      total: _notices.values.fold(0, (sum, n) => sum + n.total),
    );
  }
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
