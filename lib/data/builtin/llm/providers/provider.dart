import "dart:convert";

import "package:http/http.dart" as http;

import "../../../../core/tls.dart";
import "../../../../domain/llm_provider.dart";
import "../../../../domain/model_capability.dart";
import "../../../../domain/model_registry.dart";
import "../hosted_models.dart";
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
  Uri? get modelsUrl {
    final url = config.modelsEndpoint;
    return url == null ? null : Uri.parse(url);
  }

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

  /// The headers a request to it carries [apiKey] in.
  Map<String, String> authOf(String? apiKey) => OpenAiClient.authOf(apiKey);

  /// [modelsUrl]'s models where one is set, else [models] from models.dev.
  Future<List<String>> listModels(
    String? apiKey, {
    http.Client? httpClient,
  }) async {
    final url = modelsUrl;
    if (url == null) {
      return [for (final m in models(ModelCatalog.current)) m.id];
    }
    final client = httpClient ?? tlsClient();
    try {
      return await listModelIds(client, url, headers: authOf(apiKey));
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Whether the provider accepts [apiKey]. Throws an [LlmException] where it
  /// could not be asked, which is not a no.
  Future<bool> checkKey(String apiKey, {http.Client? httpClient});

  /// Every model it offers: its own, then models.dev's entry for it less what
  /// it has retired.
  List<ModelInfo> models(ModelCatalog catalog) {
    final own = {for (final m in config.customModels) m.id: m};
    return [
      ...own.values,
      ...?catalog
          .entryOf(config)
          ?.values
          .where(
            (m) => !own.containsKey(m.id) && !retiredModels.contains(m.id),
          ),
    ];
  }

  /// [id] as each thing it can do here, which is what its API answers: chat,
  /// unless a class says more. One this provider does not describe — a pick
  /// made before the catalog arrived, a model only its own list names — is
  /// taken to be anything the API answers, since it was picked for that.
  List<Model> serve(String id, ModelInfo? info, ModelHost host) => [
    if (info?.talks ?? true)
      HostedChatModel((
        providerId: this.id,
        modelId: id,
      ), info ?? ModelInfo(id: id)),
  ];

  /// Every model it describes, as what each can do.
  Iterable<Model> offered(ModelCatalog catalog, ModelHost host) => [
    for (final m in models(catalog)) ...serve(m.id, m, host),
  ];

  /// [modelId] as a [T], where this provider serves one.
  T? resolve<T extends Model>(String modelId, ModelHost host) => serve(
    modelId,
    ModelCatalog.current.lookup(config, modelId),
    host,
  ).whereType<T>().firstOrNull;

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
      if (status >= 200 && status < 300 || status == 402 || status == 429) {
        return true;
      }
      if (rejecting.contains(status)) return false;
      throw LlmException("Could not check the key", statusCode: status);
    } finally {
      if (httpClient == null) client.close();
    }
  }
}

/// [ref] as a [T] from the first of [providers] with its id, the one that
/// shadows any later, made with what [host] gives that provider.
T? resolveIn<T extends Model>(
  Iterable<LlmProvider> providers,
  ModelRef ref,
  ModelHost Function(LlmProvider provider) host,
) {
  final provider = providers.where((p) => p.id == ref.providerId).firstOrNull;
  return provider?.resolve<T>(ref.modelId, host(provider));
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
      OpenAiClient(baseUrl: baseUrl, apiKey: apiKey);

  @override
  List<Model> serve(String id, ModelInfo? info, ModelHost host) {
    final ref = (providerId: this.id, modelId: id);
    final known = info ?? ModelInfo(id: id);
    // The client is built when a model runs, never to say what it is.
    OpenAiClient client() => host.client() as OpenAiClient;
    return [
      ...super.serve(id, info, host),
      if (info?.makesImages ?? true)
        HostedImageModel(
          ref,
          known,
          ({quality}) =>
              (prompt) =>
                  client().generateImage(prompt, model: id, quality: quality),
        ),
      if (transcribes(id, info) && host.cutsUtterances)
        HostedTranscriptionModel(
          ref,
          known,
          (wav) => client().transcribe(wav, model: id),
        ),
      if (info?.speaks ?? true)
        HostedSynthesisModel(
          ref,
          known,
          ({voice}) =>
              (text) => client().speak(text, model: id, voice: voice),
        ),
    ];
  }

  /// Whether [id] answers transcription here: what models.dev says, and for
  /// one it does not describe, yes — it was picked for that.
  bool transcribes(String id, ModelInfo? info) => info?.transcribes ?? true;

  /// What the key is asked about: the model list, which most of these keep
  /// behind it.
  String get keyCheckPath => "models";

  /// The statuses that mean the key was refused.
  Set<int> get refusingStatuses => const {401, 403};

  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) =>
      LlmProvider.askWith(
        http.Request("GET", under(baseUrl, keyCheckPath))
          ..headers.addAll(authOf(apiKey)),
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
