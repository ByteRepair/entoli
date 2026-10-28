import "dart:convert";

import "package:http/http.dart" as http;

import "../../../../core/tls.dart";
import "../../../../domain/llm_provider.dart";
import "../../../../domain/model_registry.dart";
import "../../../../domain/voice.dart" show Synthesize, Transcribe;
import "../http_stream.dart";
import "../llm_client.dart";
import "../openai_client.dart";

/// A configured endpoint, and everything about it that differs by who runs it
/// rather than by the wire format it speaks: how a key is checked, which of
/// models.dev's models it offers, what it shows the user. The wire formats
/// are the clients; a provider has one rather than being one, since half of
/// these speak the same protocol.
///
/// Which class a config is read as is `providerOf`'s to decide.
abstract class LlmProvider {
  const LlmProvider(this.config, [this.terms]);

  final LlmProviderConfig config;

  /// What the Add provider list says beside it. Null for an endpoint typed in
  /// by hand.
  final PresetTerms? terms;

  String get id => config.id;
  String get displayName => config.displayName;
  Uri get baseUrl => Uri.parse(config.baseUrl);
  Uri? get modelsUrl =>
      config.modelsEndpoint == null ? null : Uri.parse(config.modelsEndpoint!);

  /// False for a server nothing guards, whose key the dialog does not ask for.
  bool get needsKey => true;

  /// Whether a PDF goes to it as a block. Most compatible servers reject the
  /// `file` part outright, so it is off unless the provider is known to take
  /// one.
  bool get takesPdfs => false;

  /// What the Image LLM's Default resolves to. Null where it makes no images.
  String? get imageModel => null;

  /// Models the provider has retired but models.dev still lists, kept out of
  /// the picker. By hand: nothing a provider answers says which they are.
  Set<String> get retiredModels => const {};

  LlmClient client(String? apiKey);

  /// Whether the provider accepts [apiKey]. Throws an [LlmException] where it
  /// could not be asked, which is not a no.
  Future<bool> checkKey(String apiKey, {http.Client? httpClient});

  /// Whether it has speech-to-text and text-to-speech endpoints. Read where no
  /// client should be built for it: the voice readiness gates run on every
  /// settings write.
  bool get answersAudio;

  /// [model] making one image from a prompt, over [client] — the one [client]
  /// built. Null where the provider makes no images.
  ImageGenerator? imageGenerator(LlmClient client, String model, {String? quality});

  /// [model] hearing a WAV, over [client]. Null where [answersAudio] is false.
  Transcribe? transcriber(LlmClient client, String model);

  /// [model] speaking text, over [client]. Null where [answersAudio] is false.
  Synthesize? synthesizer(LlmClient client, String model, {String? voice});

  /// Every model it offers: its own, then models.dev's entry for it less what
  /// it has retired.
  List<ModelInfo> models(ModelCatalog catalog) {
    final own = {for (final m in config.customModels) m.id: m};
    return [
      ...own.values,
      ...?catalog
          .entryOf(config)
          ?.values
          .where((m) => !own.containsKey(m.id) && !retiredModels.contains(m.id)),
    ];
  }

  /// [request] sent with the key on it, answered by its status: success is
  /// yes, one of [rejecting] is no. A spent balance or a rate limit is a key
  /// that was accepted. Anything else could not tell.
  static Future<bool> askWith(
    http.BaseRequest request, {
    http.Client? httpClient,
    Set<int> rejecting = const {401, 403},
  }) async {
    final client = httpClient ?? tlsClient();
    try {
      final response = await sendOrUnreachable(client, request);
      final status = response.statusCode;
      await response.stream.drain<void>();
      if (status >= 200 && status < 300 || status == 402 || status == 429) return true;
      if (rejecting.contains(status)) return false;
      throw LlmException("Could not check the key", statusCode: status);
    } finally {
      if (httpClient == null) client.close();
    }
  }
}

typedef ImageGenerator = Future<List<LlmAttachment>> Function(String prompt);

/// A provider that makes no images and has no audio endpoints.
mixin ChatOnly on LlmProvider {
  @override
  bool get answersAudio => false;

  @override
  ImageGenerator? imageGenerator(LlmClient client, String model, {String? quality}) =>
      null;

  @override
  Transcribe? transcriber(LlmClient client, String model) => null;

  @override
  Synthesize? synthesizer(LlmClient client, String model, {String? voice}) => null;
}

/// A server nothing guards: no key is asked for, and any key is a yes.
mixin KeyFree on LlmProvider {
  @override
  bool get needsKey => false;

  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) async => true;
}

/// Anything that copied OpenAI's `/chat/completions`, and what an endpoint
/// typed in by hand is read as. The image and audio endpoints are OpenAI's
/// shape too, so they are offered wherever an image or speech model is picked.
class OpenAiCompatibleProvider extends LlmProvider {
  const OpenAiCompatibleProvider(super.config, [super.terms]);

  @override
  OpenAiClient client(String? apiKey) =>
      OpenAiClient(baseUrl: baseUrl, apiKey: apiKey, modelsUrl: modelsUrl);

  @override
  bool get answersAudio => true;

  @override
  ImageGenerator? imageGenerator(LlmClient client, String model, {String? quality}) =>
      (prompt) => (client as OpenAiClient)
          .generateImage(prompt, model: model, quality: quality);

  @override
  Transcribe? transcriber(LlmClient client, String model) =>
      (wav) => (client as OpenAiClient).transcribe(wav, model: model);

  @override
  Synthesize? synthesizer(LlmClient client, String model, {String? voice}) =>
      (text) => (client as OpenAiClient).speak(text, model: model, voice: voice);

  /// What the key is asked about: the model list, which most of these keep
  /// behind it.
  String get keyCheckPath => "models";

  /// The statuses that mean the key was refused.
  Set<int> get refusingStatuses => const {401, 403};

  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) => LlmProvider.askWith(
        http.Request("GET", under(baseUrl, keyCheckPath))
          ..headers.addAll(OpenAiClient.authOf(apiKey)),
        httpClient: httpClient,
        rejecting: refusingStatuses,
      );
}

/// A one-token reply from the light model, for a provider whose model list is
/// public or not there: a completion is the one thing every one of them keeps
/// behind the key.
mixin ChecksKeyByCompletion on OpenAiCompatibleProvider {
  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) {
    final model = config.defaultLightModelId ?? config.defaultModelId;
    if (model == null) return super.checkKey(apiKey, httpClient: httpClient);
    return LlmProvider.askWith(
      http.Request("POST", under(baseUrl, "chat/completions"))
        ..headers.addAll({
          ...OpenAiClient.authOf(apiKey),
          "content-type": "application/json",
        })
        ..body = jsonEncode({
          "model": model,
          "max_tokens": 1,
          "messages": [
            {"role": "user", "content": "hi"},
          ],
        }),
      httpClient: httpClient,
    );
  }
}
