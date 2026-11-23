import "llm_provider.dart";
import "local_model.dart";

/// The models on this device, text and voice, as one provider.
const onDeviceConfig = LlmProviderConfig(
  id: localProviderId,
  name: "On-device",
  api: LlmApi.openai,
  // Empty, and it has to be: there is no one server behind this entry, and each
  // text model is its own process on a port of its own. The endpoint carries
  // the client that routes between them, so nothing reads this — and an empty
  // string keeps the registry's cache signature still while servers come and go
  // under it.
  baseUrl: "",
);

enum LocalLlmPhase { starting, ready, failed }

/// One loaded model, and how far it has got: what the On-device page draws
/// for every engine.
class LocalLlmState {
  const LocalLlmState({
    required this.modelId,
    required this.phase,
    this.device,
    this.contextLength,
    this.failure,
  });

  /// The catalog id being served, which is also the model id the picker offers.
  final String modelId;

  final LocalLlmPhase phase;

  /// The device it ended up on, named the way the picker names one — so
  /// [LocalDevice.cpu] where it offloads nothing. Resolved rather than chosen:
  /// this is what the auto setting turned out to mean, which is the one thing
  /// the picker cannot show.
  final String? device;

  /// The context it was loaded with.
  final int? contextLength;

  /// Why it is not running, where [phase] is [LocalLlmPhase.failed]. It is the
  /// server's own last words, which for a model too large to fit is the only
  /// place that is said.
  final String? failure;
}

/// Why the model is not answering, worded by whatever loaded it. Its own type so the
/// agent's error arm can say "the on-device model" rather than reporting a
/// connection to localhost that was refused.
class LocalLlmFailure implements Exception {
  const LocalLlmFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How many models may be resident at once, and what the settings page offers.
///
/// Two is the ceiling rather than a number to type: each is its own process
/// with its own weights and its own [kvBudgetBytes] of KV cache, and a phone
/// that could hold three of those is not the phone this is written for. Two is
/// worth having because the pair is not symmetric — a small model naming chats
/// beside a large one answering them costs far less than the large one twice.
const maxLocalModelsAllowed = 2;
