import "model_info.dart";
import "voice.dart";

/// A model as a setting names it: the provider it is reached through and its id
/// there. Both halves, always — two providers can serve the same id.
typedef ModelRef = ({String providerId, String modelId});

/// One thing one model can do, served by one provider. What it can do is its
/// type: a model that both chats and draws is two of these sharing a [ref], and
/// "can it speak" is "is there a [SynthesisModel] for it".
///
/// Running it is not the provider's business. A hosted model runs over its
/// provider's client and an on-device one on whatever this platform brought —
/// sherpa, the system's engines, the llama pool — which each implementation
/// holds rather than the provider.
abstract class Model {
  ModelRef get ref;

  /// What is known of it: models.dev's entry, one added by hand, or what the
  /// app says of its own on-device models.
  ModelInfo get info;
}

/// Answers turns and background completions. Run through the provider's
/// client, which the registry keys by [Model.ref]'s provider.
abstract interface class ChatModel implements Model {}

/// Hears speech, for voice mode.
abstract interface class TranscriptionModel implements Model {
  Hearing get hearing;

  /// The device's own engine, which is asked for a language rather than
  /// being one.
  bool get systemEngine;
}

/// Speaks text, for voice mode and reading a reply out. [voice] is a hosted
/// provider's name for one; an on-device model's speaker is picked apart.
abstract interface class SynthesisModel implements Model {
  Speaking speaking({String? voice});

  /// See [TranscriptionModel.systemEngine]. Its voice is the user's, set in
  /// the OS.
  bool get systemEngine;

  /// Whether a voice is picked by the provider's name for one.
  bool get namesVoices;

  /// How many voices it has to pick between by number, none where a voice is
  /// named or the OS picks it.
  int get speakers;
}
