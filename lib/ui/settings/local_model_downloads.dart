import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/background_work.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../../providers.dart";

/// What is being fetched, what failed, and what is asked to be removed. Held
/// above the settings page rather than in it, for the reason the rootfs and
/// voice downloads are: closing settings must not cancel a download, and on
/// Android it has to outlive the app being on screen, which is what the
/// notification is for.
///
/// These are the largest downloads the app makes — a couple of gigabytes where
/// a rootfs is four megabytes — so the notification matters more here than
/// anywhere else it is used.
class LocalModelDownloads extends Notifier<LocalModelDownloadState> {
  final _running = <String, StreamSubscription<LocalModelProgress>>{};

  @override
  LocalModelDownloadState build() {
    final work = ref.watch(backgroundWorkProvider);
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
      unawaited(work.downloading(null));
    });
    return const LocalModelDownloadState();
  }

  void install(LocalModel model) {
    if (_running.containsKey(model.id)) return;
    _publish(
      active: {
        ...state.active,
        model.id: LocalModelProgress(received: 0, total: model.bytes),
      },
      failures: {...state.failures}..remove(model.id),
    );
    _running[model.id] = ref.read(localModelStoreProvider).install(model).listen(
          (progress) => _publish(active: {...state.active, model.id: progress}),
          onError: (Object e) => _finish(model.id, failure: "$e"),
          onDone: () {
            _finish(model.id);
            unawaited(ref.read(installedLocalModelsProvider.notifier).refresh());
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

  /// Remove it, and stop serving it first. The unpick is the load-bearing half
  /// and it is more so here than for a rootfs: the server has the file open, so
  /// deleting under it leaves a model answering out of a file that is no longer
  /// on disk — and a provider in every picker that nothing could rebuild.
  Future<void> delete(LocalModel model) async {
    if (ref.read(appSettingsProvider).localModelId == model.id) {
      await ref.read(appSettingsProvider.notifier).setLocalModel(null);
    }
    await ref.read(localModelStoreProvider).delete(model);
    await ref.read(installedLocalModelsProvider.notifier).refresh();
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
    Map<String, LocalModelProgress>? active,
    Map<String, String>? failures,
  }) {
    state = LocalModelDownloadState(
      active: active ?? state.active,
      failures: failures ?? state.failures,
    );
    unawaited(ref.read(backgroundWorkProvider).downloading(state.notice));
  }
}

class LocalModelDownloadState {
  const LocalModelDownloadState({this.active = const {}, this.failures = const {}});

  /// By id, so the row that is downloading finds its own bar.
  final Map<String, LocalModelProgress> active;

  /// Why one stopped. Cleared when it is tried again.
  final Map<String, String> failures;

  DownloadNotice? get notice {
    if (active.isEmpty) return null;
    final label = active.length == 1
        ? (localModelById(active.keys.single)?.name ?? "Model")
        : "${active.length} models";
    return DownloadNotice(
      label: label,
      received: active.values.fold(0, (sum, p) => sum + p.received),
      total: active.values.fold(0, (sum, p) => sum + p.total),
    );
  }
}

final localModelDownloadsProvider =
    NotifierProvider<LocalModelDownloads, LocalModelDownloadState>(
        LocalModelDownloads.new);
