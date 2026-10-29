import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/installable.dart";
import "../../domain/local_model.dart";
import "../../providers.dart";
import "downloads.dart";

/// Every on-device model's half of [Downloads], text and voice alike: each
/// [Installable] says where it comes from and goes. The largest downloads the
/// app makes, a couple of gigabytes for a text model, which is what makes the
/// notification matter more here than anywhere else it is used.
class ModelDownloads extends Downloads<Installable> {
  @override
  String idOf(Installable model) => model.id;

  /// Every entry can be fetched wherever its catalogue is drawn, and each is
  /// drawn only where something can run it.
  @override
  Download? begin(Installable model) =>
      Download(bytes: model.bytes, progress: model.install());

  @override
  String nameOf(Installable model) => model.name;

  @override
  String get plural => "models";

  /// One added by link leaves [addedLocalModelsProvider] once it is on disk,
  /// where it is listed as downloaded like any other.
  @override
  Future<void> rescan() async {
    await ref.read(installedVoiceModelsProvider.notifier).refresh();
    await ref.read(installedLocalModelsProvider.notifier).refresh();
    ref.read(addedLocalModelsProvider.notifier).drop(ref.read(installedLocalModelsProvider));
  }

  /// One added by link and stopped before it arrived goes with its row.
  @override
  void cancel(String id) {
    super.cancel(id);
    ref.read(addedLocalModelsProvider.notifier).drop({id});
  }

  /// Stop using it before it goes, which is the load-bearing half of a
  /// delete: a voice pick left naming it resolves to nothing, so voice mode
  /// would stay off with no word of why; and the server has a text model's
  /// file open, so deleting under it leaves a model answering out of a file
  /// that is no longer there.
  ///
  /// The whole pool is stopped rather than the one model, and that is the
  /// whole reason there is no `stop(id)`: a delete is rare, whatever else was
  /// up reloads on the next turn that asks for it, and a pool that can be told
  /// to drop one member by name is a second way to get the list wrong.
  @override
  Future<void> unpick(Installable model) async {
    final settings = ref.read(appSettingsProvider.notifier);
    final picked = (providerId: localProviderId, modelId: model.id);
    if (voiceRecognitionChoice(ref.read(appSettingsProvider)) == picked) {
      await settings.setVoiceRecognitionModel(null);
    }
    if (voiceSpeechChoice(ref.read(appSettingsProvider)) == picked) {
      await settings.setVoiceSpeechModel(null);
    }
    final llm = ref.read(localLlmProvider);
    if (llm.running.value.any((each) => each.modelId == model.id)) await llm.stopAll();
  }

  @override
  Future<void> erase(Installable model) => model.delete();
}

final modelDownloadsProvider =
    NotifierProvider<ModelDownloads, DownloadState>(ModelDownloads.new);

/// Models added by link this session that are not on disk yet: a row each,
/// with its bar, until the download lands or is cancelled. A failed one stays
/// with the button to try again.
class AddedLocalModels extends Notifier<List<LocalModel>> {
  @override
  List<LocalModel> build() => const [];

  void add(LocalModel model) => state = [...state, model];

  void drop(Set<String> ids) {
    if (state.any((model) => ids.contains(model.id))) {
      state = [for (final model in state) if (!ids.contains(model.id)) model];
    }
  }
}

final addedLocalModelsProvider =
    NotifierProvider<AddedLocalModels, List<LocalModel>>(AddedLocalModels.new);
