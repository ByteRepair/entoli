/// Asks the platform not to kill the app while there is work it must not lose.
/// Android's foreground services; a no-op everywhere else, where a process
/// nobody is looking at is left alone.
///
/// Nothing about the work moves. It runs in the isolate it always ran in; this
/// only buys that isolate the right to keep running off screen, and offers the
/// user a way to stop it from outside the app.
library;

import "package:flutter/foundation.dart" show listEquals;

/// What the process is being held open for, each one a different thing to
/// stop — and Android insists the one holding the microphone be a service of
/// a different type from the others that are not.
enum BackgroundJob { turns, voice, download, prefill, sync }

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

/// The connected sync peers, while the keep-alive setting is on. Names rather
/// than a count and a rendering of them: the count and the line the
/// notification words from it are the one renderer's, which is Kotlin's —
/// the same shape `DownloadNotice` keeps, a label rather than a layout. By
/// value, so the keep-alive can answer "is this the same notice as last time"
/// without crossing the channel to ask.
class SyncNotice {
  const SyncNotice({required this.names});

  final List<String> names;

  @override
  bool operator ==(Object other) =>
      other is SyncNotice && listEquals(other.names, names);

  @override
  int get hashCode => Object.hashAll(names);
}

/// The one caller of [BackgroundWork.downloading].
///
/// Three catalogs fetch into one platform slot — a voice model, a Linux, and a
/// model to run on the device — and `downloading(null)` stops the foreground
/// service outright. So a four-megabyte rootfs finishing while a two-gigabyte
/// model is still streaming would drop the hold and leave the app killable in
/// the middle of the longest download it makes. Merging here makes that
/// unrepresentable rather than a rule each of the three has to keep.
///
/// `Downloads` is the only thing that holds one, and its `plural` is the source
/// name — each catalog has one and they are distinct, so there is nothing else
/// to invent.
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

  /// The on-device model whose system prompt is being prefilled, or null when
  /// none is. Unlike the other three this one is meant to be *seen* — it is
  /// work the user set going and then left, so its notification is a visible
  /// one rather than the silent hold the others keep. The model names it, so
  /// its wording comes from here rather than Kotlin, the way a download's does.
  Future<void> prefilling(String? model);

  /// The connected peers to hold the process open for, or null when there are
  /// none — or when the keep-alive setting is off, which is the same answer:
  /// the hold is the setting's, and reporting through it is how both say stop.
  Future<void> syncing(SyncNotice? notice);

  /// The user said stop from outside the app — each notification has a button,
  /// and this says which was pressed. Whoever owns that kind of work stops it,
  /// which is what then takes the notification away: the button asks, it does
  /// not act.
  Stream<BackgroundJob> get stopRequests;
}
