import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/background_work.dart";
import "../../domain/download.dart";
import "../../providers.dart";

/// What a catalog of downloadable things has downloaded, is downloading, and is
/// asked to remove. Held above the settings page rather than in it: a download
/// outlives the page — closing settings must not cancel a hundred megabytes —
/// and on Android it outlives the app being on screen, which is what the
/// notification is for.
///
/// One class for both catalogs. What each of them answers is the six hooks
/// below; everything else here — the running subscriptions, the stop button in
/// the notification, the release on dispose, the order a delete happens in — is
/// the part that was written twice and had to stay in step.
abstract class Downloads<T> extends Notifier<DownloadState> {
  /// What is in flight, by id, and the item each one is — kept beside its
  /// subscription rather than looked up again, since the notification needs the
  /// name of something [install] was handed three lines earlier.
  final _running = <String, ({T item, StreamSubscription<DownloadProgress> sub})>{};

  /// The id [item] is filed under, which is what a row and a notice find each
  /// other by.
  String idOf(T item);

  /// Start fetching [item], or null where this device has nothing to fetch for
  /// it — an architecture with no image, a platform with no store. Null is a
  /// press that does nothing rather than a download that fails, and the button
  /// that raised it is expected to have been dead already.
  Download? begin(T item);

  /// What the notification calls one of these, and the plural it counts them
  /// in — "3 voice models", "3 systems". Two words from the catalog rather
  /// than a sentence, since the counting is the same either way.
  String nameOf(T item);
  String get plural;

  /// Read what is installed again. The only thing that changes that answer is
  /// a download finishing or a delete, which are both here.
  Future<void> rescan();

  /// Stop using [item] before it goes. This is the load-bearing half of a
  /// delete: both catalogs resolve a pick against the catalog rather than the
  /// disk, so a setting left naming something deleted fails later and
  /// elsewhere — at the microphone, or in the middle of a turn.
  Future<void> unpick(T item);

  /// Take it off the disk.
  Future<void> erase(T item);

  @override
  DownloadState build() {
    final work = ref.watch(backgroundWorkProvider);
    final stops = work.stopRequests
        .where((job) => job == BackgroundJob.download)
        .listen((_) => cancelAll());
    ref.onDispose(() {
      unawaited(stops.cancel());
      for (final running in _running.values) {
        unawaited(running.sub.cancel());
      }
      // Released, not merely abandoned: a restore restarts the app by throwing
      // this container away, and a hold nobody let go of leaves the
      // notification up and `ForegroundWork.busy` true for good — after which
      // the cached engine is never evicted again.
      unawaited(work.downloading(null));
    });
    return const DownloadState();
  }

  void install(T item) {
    final id = idOf(item);
    if (_running.containsKey(id)) return;
    final download = begin(item);
    if (download == null) return;
    // Held before the first publish, not after: the notification names what is
    // running by looking it up here, and a stream delivers nothing until the
    // event loop turns, so there is no race in listening first.
    _running[id] = (
      item: item,
      sub: download.progress.listen(
        (progress) => _publish(active: {...state.active, id: progress}),
        onError: (Object e) => _finish(id, failure: "$e"),
        onDone: () {
          _finish(id);
          unawaited(rescan());
        },
      ),
    );
    _publish(
      active: {...state.active, id: DownloadProgress(received: 0, total: download.bytes)},
      failures: {...state.failures}..remove(id),
    );
  }

  /// Cancelling the subscription is what cancels the download: the store's
  /// stream cleans up the half-written directory when its listener goes.
  void cancel(String id) {
    unawaited(_running[id]?.sub.cancel());
    _finish(id);
  }

  void cancelAll() {
    for (final id in _running.keys.toList()) {
      cancel(id);
    }
  }

  /// Unpick, erase, then look again — in that order, and here rather than in
  /// the widget so that a second caller cannot skip the first step.
  Future<void> delete(T item) async {
    await unpick(item);
    await erase(item);
    await rescan();
  }

  void _finish(String id, {String? failure}) {
    _running.remove(id);
    _publish(
      active: {...state.active}..remove(id),
      failures: failure == null ? null : {...state.failures, id: failure},
    );
  }

  /// Publishes and tells the platform in one place, so the notification can
  /// never disagree with the bar in settings.
  ///
  /// The bar is redrawn on every event and the notification is not. A progress
  /// event arrives once a megabyte, and telling Android each time is a channel
  /// call, a map encoded, and a notification rebuilt through five binder calls
  /// — some fourteen hundred of them for a rootfs, for a bar a hundred pixels
  /// wide. So it is told when what it would *say* changes: a different set of
  /// downloads, or another whole percent.
  void _publish({
    Map<String, DownloadProgress>? active,
    Map<String, String>? failures,
  }) {
    state = DownloadState(
      active: active ?? state.active,
      failures: failures ?? state.failures,
    );
    final notice = _notice();
    final at = notice == null || notice.total <= 0
        ? -1
        : notice.received * 100 ~/ notice.total;
    if (notice?.label == _told && at == _toldAt) return;
    _told = notice?.label;
    _toldAt = at;
    unawaited(ref.read(backgroundWorkProvider).downloading(notice));
  }

  /// What the notification was last told, so that an event which would not
  /// change it does not cost a channel call.
  String? _told;
  int _toldAt = -1;

  /// What the notification says, or null when there is nothing to say. Several
  /// at once are one line rather than several notifications: they share a
  /// Cancel, and a column of progress bars is not what a notification shade is
  /// for.
  DownloadNotice? _notice() {
    final active = state.active;
    if (active.isEmpty) return null;
    return DownloadNotice(
      label: active.length == 1
          ? nameOf(_running[active.keys.single]!.item)
          : "${active.length} $plural",
      received: active.values.fold(0, (sum, p) => sum + p.received),
      total: active.values.fold(0, (sum, p) => sum + p.total),
    );
  }
}

/// A download that has been started: what it will amount to, and how it is
/// getting on. The size is separate because the bar reads it before the first
/// byte lands, and the stream is the store's own.
class Download {
  const Download({required this.bytes, required this.progress});

  final int bytes;
  final Stream<DownloadProgress> progress;
}

class DownloadState {
  const DownloadState({this.active = const {}, this.failures = const {}});

  /// By id, so the row that is downloading finds its own bar.
  final Map<String, DownloadProgress> active;

  /// Why one stopped, by id. Cleared when it is tried again.
  final Map<String, String> failures;
}
