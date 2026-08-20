import "../../../domain/llm_provider.dart";
import "../../../domain/models.dart";
import "anthropic_client.dart";
import "llm_client.dart";
import "openai_client.dart";

/// Turns the configured providers into clients, and answers what they can run.
/// Both inputs are read when used rather than captured: the settings page
/// edits them, and it does so long after this was built.
class LlmRegistry {
  LlmRegistry({
    required this.providers,
    required this.lookupEnv,
    LlmClient Function(LlmProviderConfig config, String? apiKey)? build,
  }) : _build = build ?? defaultBuild;

  final List<LlmProviderConfig> Function() providers;

  /// One variable at a time, rather than a whole environment: the only use is
  /// finding a named key, and building a map of the process environment to
  /// answer that copies a hundred entries per lookup.
  final String? Function(String name) lookupEnv;

  final LlmClient Function(LlmProviderConfig config, String? apiKey) _build;

  final Map<String, ({String signature, LlmClient client})> _clients = {};

  LlmProviderConfig? configFor(String providerId) {
    for (final provider in providers()) {
      if (provider.id == providerId) return provider;
    }
    return null;
  }

  /// Null when nothing is configured under that name — the caller says so,
  /// rather than a request failing against a guessed endpoint.
  LlmClient? clientFor(String providerId) {
    final config = configFor(providerId);
    return config == null ? null : clientOf(config);
  }

  /// For a config already in hand. Callers that have just read the provider
  /// list use this rather than going back through [configFor], which would
  /// read and parse `settings.json` all over again.
  LlmClient clientOf(LlmProviderConfig config) {
    final key = config.resolveKeyWith(lookupEnv);
    // A URL or key edited in settings has to reach the next turn, so a cached
    // client built from the old one is dropped rather than reused.
    final signature = "${config.api.name}|${config.baseUrl}|$key";
    final cached = _clients[config.id];
    if (cached != null && cached.signature == signature) return cached.client;
    cached?.client.close();
    final client = _build(config, key);
    _clients[config.id] = (signature: signature, client: client);
    return client;
  }

  /// Every model the configured providers offer. A provider that lists its own
  /// is taken at its word; otherwise the endpoint is asked — all of them at
  /// once, since one slow host should not hold up the rest, and one that
  /// cannot answer contributes nothing rather than failing the whole list.
  Future<List<ModelOption>> models() async {
    final configured = providers();
    final lists = await Future.wait(configured.map(
        (p) => p.models.isNotEmpty ? Future.value(p.models) : _listFrom(p)));
    return [
      for (var i = 0; i < configured.length; i++)
        for (final id in lists[i])
          ModelOption(
            providerId: configured[i].id,
            modelId: id,
            label: "${configured[i].displayName} · $id",
          ),
    ];
  }

  /// Bounded: an endpoint configured but unreachable — a stale localhost, a
  /// host that drops packets — would otherwise hold the model picker for the
  /// whole OS connect timeout.
  Future<List<String>> _listFrom(LlmProviderConfig provider) async {
    try {
      return await clientOf(provider)
          .listModels()
          .timeout(const Duration(seconds: 10), onTimeout: () => const []);
    } catch (_) {
      return const [];
    }
  }

  void close() {
    for (final entry in _clients.values) {
      entry.client.close();
    }
    _clients.clear();
  }

  /// What a provider gets when the caller says nothing. Public because one
  /// caller does say something: the on-device server is an ordinary
  /// OpenAI-shaped endpoint that happens to need waiting for, so it is this
  /// wrapped rather than a client of its own — see `PendingLlmClient`.
  static LlmClient defaultBuild(LlmProviderConfig config, String? apiKey) =>
      switch (config.api) {
        LlmApi.anthropic =>
          AnthropicClient(baseUrl: Uri.parse(config.baseUrl), apiKey: apiKey),
        LlmApi.openai => OpenAiClient(baseUrl: Uri.parse(config.baseUrl), apiKey: apiKey),
      };
}
