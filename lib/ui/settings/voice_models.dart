import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/background_work.dart";
import "../../domain/voice_model.dart";
import "../../domain/voice_model_store.dart";
import "../../providers.dart";

/// What the app has downloaded, is downloading, and is asked to remove. Held
/// above the settings page rather than in it: a download outlives the page —
/// closing settings must not cancel a hundred megabytes — and on Android it
/// outlives the app being on screen, which is what the notification is for.
class VoiceModels extends Notifier<VoiceDownloadState> {
  late DownloadHold _hold;

  final _running = <String, StreamSubscription<VoiceModelProgress>>{};

  @override
  VoiceDownloadState build() {
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
      // Released, not merely abandoned: a restore restarts the app by throwing
      // this container away, and a hold nobody let go of leaves the
      // notification up and `ForegroundWork.busy` true for good — after which
      // the cached engine is never evicted again.
      unawaited(_hold.report("voice", null));
    });
    return const VoiceDownloadState();
  }

  void install(VoiceModel model) {
    if (_running.containsKey(model.id)) return;
    final store = ref.read(voiceModelStoreProvider);
    _publish(
      active: {
        ...state.active,
        model.id: VoiceModelProgress(received: 0, total: model.bytes),
      },
      failures: {...state.failures}..remove(model.id),
    );
    _running[model.id] = store.install(model).listen(
      (progress) => _publish(active: {...state.active, model.id: progress}),
      onError: (Object e) => _finish(model.id, failure: "$e"),
      onDone: () {
        _finish(model.id);
        unawaited(ref.read(installedVoiceModelsProvider.notifier).refresh());
      },
    );
  }

  /// Cancelling the subscription is what cancels the download: the store's
  /// stream cleans up the half-written directory when its listener goes.
  void cancel(String modelId) {
    unawaited(_running[modelId]?.cancel());
    _finish(modelId);
  }

  void cancelAll() {
    for (final id in _running.keys.toList()) {
      cancel(id);
    }
  }

  /// Remove it from disk, and unpick it first. The unpick is the load-bearing
  /// half: `voiceModelOf` reads the catalog rather than the disk, so a setting
  /// left naming a deleted model gets all the way into `SherpaVoice.start`
  /// before failing — which moves the complaint from choosing a model to
  /// pressing the microphone. Here rather than in the widget so that a second
  /// caller cannot skip it.
  Future<void> delete(VoiceModel model) async {
    final settings = ref.read(appSettingsProvider.notifier);
    if (ref.read(appSettingsProvider).voiceRecognitionModelId == model.id) {
      await settings.setVoiceRecognitionModel(null);
    }
    if (ref.read(appSettingsProvider).voiceSpeechModelId == model.id) {
      await settings.setVoiceSpeechModel(null);
    }
    await ref.read(voiceModelStoreProvider).delete(model);
    await ref.read(installedVoiceModelsProvider.notifier).refresh();
  }

  void _finish(String modelId, {String? failure}) {
    _running.remove(modelId);
    _publish(
      active: {...state.active}..remove(modelId),
      failures: failure == null ? null : {...state.failures, modelId: failure},
    );
  }

  /// Publishes and tells the platform in one place, so the notification can
  /// never disagree with the bar in settings.
  void _publish({
    Map<String, VoiceModelProgress>? active,
    Map<String, String>? failures,
  }) {
    state = VoiceDownloadState(
      active: active ?? state.active,
      failures: failures ?? state.failures,
    );
    unawaited(_hold.report("voice", state.notice));
  }
}

class VoiceDownloadState {
  const VoiceDownloadState({this.active = const {}, this.failures = const {}});

  /// By model id, for the row that is downloading to find its own bar.
  final Map<String, VoiceModelProgress> active;

  /// Why a download stopped, by model id. Cleared when it is tried again.
  final Map<String, String> failures;

  /// What the notification says, or null when there is nothing to say. Several
  /// at once are one line rather than several notifications: they share a
  /// Cancel, and a column of progress bars is not what a notification shade is
  /// for.
  DownloadNotice? get notice {
    if (active.isEmpty) return null;
    final label = active.length == 1
        ? (voiceModelById(active.keys.single)?.name ?? "voice model")
        : "${active.length} voice models";
    return DownloadNotice(
      label: label,
      received: active.values.fold(0, (sum, p) => sum + p.received),
      total: active.values.fold(0, (sum, p) => sum + p.total),
    );
  }
}

final voiceModelsProvider =
    NotifierProvider<VoiceModels, VoiceDownloadState>(VoiceModels.new);
