import "../../../domain/model_capability.dart";
import "../../../domain/model_info.dart";
import "../../../domain/voice.dart";
import "llm_client.dart";

typedef ImageGenerator = Future<List<LlmAttachment>> Function(String prompt);

/// Makes images, for the image tool. Declared here rather than beside the
/// other capabilities because what it hands back is the client's attachment.
abstract interface class ImageModel implements Model {
  ImageGenerator generator({String? quality});
}

/// What a provider's models are made with: the client that reaches it, built
/// only when a model is run, and what this platform can run them on.
class ModelHost {
  const ModelHost({required this.client, this.cutsUtterances = true});

  /// For a host that only asks what a pick resolves to — the readiness gates —
  /// and never runs one.
  ModelHost.resolving({this.cutsUtterances = true})
      : client = (() => throw StateError("Resolved to check, not to run."));

  final LlmClient Function() client;

  /// Whether the device can cut the microphone into utterances, which a hosted
  /// transcription model needs: it takes a whole WAV, not a stream.
  final bool cutsUtterances;
}

/// A hosted provider's model, each kind a call over the provider's client.
/// The calls are handed in rather than the provider, which builds these.
class HostedChatModel implements ChatModel {
  const HostedChatModel(this.ref, this.info);

  @override
  final ModelRef ref;
  @override
  final ModelInfo info;
}

class HostedImageModel implements ImageModel {
  const HostedImageModel(this.ref, this.info, this._generator);

  @override
  final ModelRef ref;
  @override
  final ModelInfo info;
  final ImageGenerator Function({String? quality}) _generator;

  @override
  ImageGenerator generator({String? quality}) => _generator(quality: quality);
}

class HostedTranscriptionModel implements TranscriptionModel {
  const HostedTranscriptionModel(this.ref, this.info, this._transcribe);

  @override
  final ModelRef ref;
  @override
  final ModelInfo info;
  final Transcribe _transcribe;

  @override
  Hearing get hearing => HearThrough(_transcribe);
}

class HostedSynthesisModel implements SynthesisModel {
  const HostedSynthesisModel(this.ref, this.info, this._synthesizer);

  @override
  final ModelRef ref;
  @override
  final ModelInfo info;
  final Synthesize Function({String? voice}) _synthesizer;

  @override
  Speaking speaking({String? voice}) => SpeakThrough(_synthesizer(voice: voice));
}
