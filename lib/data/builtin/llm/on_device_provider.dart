import "package:http/http.dart" as http;

import "../../../domain/app_settings.dart";
import "../../../domain/local_llm.dart" show onDeviceConfig;
import "../../../domain/local_model.dart" show localProviderId;
import "../../../domain/model_capability.dart";
import "../../../domain/model_registry.dart";
import "../../../domain/voice.dart";
import "../../../domain/voice_model.dart";
import "../../local/local_engine.dart";
import "hosted_models.dart";
import "llm_client.dart";
import "providers/provider.dart";

/// Every model on this device as one provider, an entry the user never
/// configures: the downloaded text models, run by the platform's
/// [LocalEngine], and the voice models, run by the platform's [Voice]. No key
/// reaches it.
///
/// Always there, with nothing in it until something is downloaded — an empty
/// provider is in no picker, so nothing has to keep it out of one.
class OnDeviceProvider extends LlmProvider with KeyFree {
  const OnDeviceProvider(this._engine, this._settings, {required this.voices})
      : super(onDeviceConfig);

  final LocalEngine _engine;
  final AppSettings Function() _settings;

  /// The voice models usable here: downloaded, or a system engine the device
  /// has. Read when asked, since a download lands while this is held.
  final Set<String> Function() voices;

  @override
  LlmClient client(String? apiKey) => _engine.client(_settings);

  /// The text models alone, which are what a chat lists. Answered from what is
  /// on disk rather than by asking the engine, since asking would mean loading
  /// one.
  @override
  Future<List<String>> listModels(String? apiKey, {http.Client? httpClient}) async =>
      _engine.installed;

  /// What it has is on the disk, not in models.dev, so [info] says nothing and
  /// an id it has not got is nothing at all.
  @override
  List<Model> serve(String id, ModelInfo? info, ModelHost host) {
    final ref = (providerId: localProviderId, modelId: id);
    final voice = voices().contains(id) ? voiceModelById(id) : null;
    return [
      if (_engine.installed.contains(id))
        HostedChatModel(ref, ModelInfo(id: id, toolCall: true)),
      if (voice is RecognitionModel) OnDeviceTranscriptionModel(ref, voice),
      if (voice is SpeechModel) OnDeviceSynthesisModel(ref, voice),
    ];
  }

  @override
  Iterable<Model> offered(ModelCatalog catalog, ModelHost host) =>
      [for (final id in {..._engine.installed, ...voices()}) ...serve(id, null, host)];
}

/// A voice model on the device, as the platform's [Voice] runs it.
class OnDeviceTranscriptionModel implements TranscriptionModel {
  const OnDeviceTranscriptionModel(this.ref, this.model);

  @override
  final ModelRef ref;
  final RecognitionModel model;

  @override
  ModelInfo get info =>
      ModelInfo(id: model.id, name: model.name, talks: false, transcribes: true);

  @override
  Hearing get hearing => HearOnDevice(model);

  @override
  bool get systemEngine => model.isNative;
}

class OnDeviceSynthesisModel implements SynthesisModel {
  const OnDeviceSynthesisModel(this.ref, this.model);

  @override
  final ModelRef ref;
  final SpeechModel model;

  @override
  ModelInfo get info => ModelInfo(id: model.id, name: model.name, talks: false, speaks: true);

  /// A hosted provider's voice means nothing here: which of the model's
  /// speakers reads is its own setting.
  @override
  Speaking speaking({String? voice}) => SpeakOnDevice(model);

  @override
  bool get systemEngine => model.isNative;

  @override
  bool get namesVoices => false;

  @override
  int get speakers => model.isNative ? 0 : model.speakers;
}

