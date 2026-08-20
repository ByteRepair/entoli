import "package:flutter_riverpod/flutter_riverpod.dart";

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

  /// Both halves, since one model can be picked as either — and `voiceModelOf`
  /// reads the catalog rather than the disk, so a setting left naming a deleted
  /// model gets all the way into `SherpaVoice.start` before failing, which
  /// moves the complaint from choosing a model to pressing the microphone.
  @override
  Future<void> unpick(VoiceModel model) async {
    final settings = ref.read(appSettingsProvider.notifier);
    if (ref.read(appSettingsProvider).voiceRecognitionModelId == model.id) {
      await settings.setVoiceRecognitionModel(null);
    }
    if (ref.read(appSettingsProvider).voiceSpeechModelId == model.id) {
      await settings.setVoiceSpeechModel(null);
    }
  }

  @override
  Future<void> erase(VoiceModel model) =>
      ref.read(voiceModelStoreProvider).delete(model);
}

final voiceModelsProvider =
    NotifierProvider<VoiceModels, DownloadState>(VoiceModels.new);
