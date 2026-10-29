import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/local_model.dart" show localProviderId;
import "../../domain/voice_model.dart";
import "../../providers.dart";
import "downloads.dart";

/// The voice half of [Downloads]: what it is called, where it comes from, and
/// what has to stop pointing at it before it can go.
class VoiceModels extends Downloads<VoiceModel> {
  @override
  String idOf(VoiceModel model) => model.id;

  @override
  Download? begin(VoiceModel model) => Download(
        bytes: model.bytes,
        progress: ref.read(voiceModelStoreProvider).install(model),
      );

  @override
  String nameOf(VoiceModel model) => model.name;

  @override
  String get plural => "voice models";

  @override
  Future<void> rescan() =>
      ref.read(installedVoiceModelsProvider.notifier).refresh();

  /// Both halves, since one model can be picked as either. A setting left
  /// naming a deleted model resolves to nothing, so the pick would read as
  /// set while voice mode stays off with no word of why.
  @override
  Future<void> unpick(VoiceModel model) async {
    final settings = ref.read(appSettingsProvider.notifier);
    final picked = (providerId: localProviderId, modelId: model.id);
    if (voiceRecognitionChoice(ref.read(appSettingsProvider)) == picked) {
      await settings.setVoiceRecognitionModel(null);
    }
    if (voiceSpeechChoice(ref.read(appSettingsProvider)) == picked) {
      await settings.setVoiceSpeechModel(null);
    }
  }

  @override
  Future<void> erase(VoiceModel model) =>
      ref.read(voiceModelStoreProvider).delete(model);
}

final voiceModelsProvider =
    NotifierProvider<VoiceModels, DownloadState>(VoiceModels.new);
