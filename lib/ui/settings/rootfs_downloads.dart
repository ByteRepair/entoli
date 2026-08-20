import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/background_work.dart";
import "../../domain/rootfs.dart";
import "../../domain/rootfs_store.dart";
import "../../providers.dart";

/// What is being fetched, what failed, and what is asked to be removed. Held
/// above the settings page rather than in it, for the reason the voice
/// downloads are: closing settings must not cancel a download, and on Android
/// it has to outlive the app being on screen, which is what the notification is
/// for.
class RootfsDownloads extends Notifier<RootfsDownloadState> {
  late DownloadHold _hold;

  final _running = <String, StreamSubscription<RootfsProgress>>{};

  @override
  RootfsDownloadState build() {
    final work = ref.watch(backgroundWorkProvider);
    // Held rather than read in the disposer: reading a provider from a
    // life-cycle callback is what Riverpod refuses.
    _hold = ref.watch(downloadHoldProvider);
    final stops = work.stopRequests
        .where((job) => job == BackgroundJob.download)
        .listen((_) => cancelAll());
    ref.onDispose(() {
      unawaited(stops.cancel());
      for (final sub in _running.values) {
        unawaited(sub.cancel());
      }
      // Released rather than merely abandoned: a restore throws this container
      // away, and a hold nobody let go of leaves the notification up for good.
      unawaited(_hold.report("linux", null));
    });
    return const RootfsDownloadState();
  }

  void install(Rootfs rootfs) {
    if (_running.containsKey(rootfs.id)) return;
    final abi = ref.read(deviceAbiProvider);
    if (abi == null) return;
    final image = rootfs.imageFor(abi);
    if (image == null) return;
    _publish(
      active: {
        ...state.active,
        rootfs.id: RootfsProgress(received: 0, total: image.bytes),
      },
      failures: {...state.failures}..remove(rootfs.id),
    );
    _running[rootfs.id] = ref.read(rootfsStoreProvider).install(rootfs, abi: abi).listen(
          (progress) => _publish(active: {...state.active, rootfs.id: progress}),
          onError: (Object e) => _finish(rootfs.id, failure: "$e"),
          onDone: () {
            _finish(rootfs.id);
            unawaited(ref.read(installedRootfsProvider.notifier).refresh());
          },
        );
  }

  /// Cancelling the subscription is what cancels the download: the store's
  /// stream removes the half-written directory when its listener goes.
  void cancel(String id) {
    unawaited(_running[id]?.cancel());
    _finish(id);
  }

  void cancelAll() {
    for (final id in _running.keys.toList()) {
      cancel(id);
    }
  }

  /// Remove it, and stop running commands in it first. The unpick is the
  /// load-bearing half: a setting left naming a deleted rootfs would take the
  /// shell all the way to a proot with nothing to chroot into, which moves the
  /// complaint from a settings page to the middle of somebody's turn.
  Future<void> delete(Rootfs rootfs) async {
    final settings = ref.read(appSettingsProvider.notifier);
    if (ref.read(appSettingsProvider).rootfsId == rootfs.id) {
      await settings.setRootfs(null);
    }
    await ref.read(rootfsStoreProvider).delete(rootfs);
    await ref.read(installedRootfsProvider.notifier).refresh();
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
  void _publish({
    Map<String, RootfsProgress>? active,
    Map<String, String>? failures,
  }) {
    state = RootfsDownloadState(
      active: active ?? state.active,
      failures: failures ?? state.failures,
    );
    unawaited(_hold.report("linux", state.notice));
  }
}

class RootfsDownloadState {
  const RootfsDownloadState({this.active = const {}, this.failures = const {}});

  /// By id, so the row that is downloading finds its own bar.
  final Map<String, RootfsProgress> active;

  /// Why one stopped. Cleared when it is tried again.
  final Map<String, String> failures;

  DownloadNotice? get notice {
    if (active.isEmpty) return null;
    final label = active.length == 1
        ? (rootfsById(active.keys.single)?.name ?? "Linux")
        : "${active.length} systems";
    return DownloadNotice(
      label: label,
      received: active.values.fold(0, (sum, p) => sum + p.received),
      total: active.values.fold(0, (sum, p) => sum + p.total),
    );
  }
}

final rootfsDownloadsProvider =
    NotifierProvider<RootfsDownloads, RootfsDownloadState>(RootfsDownloads.new);
