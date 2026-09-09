import "../../../domain/llm_provider.dart";
import "../../../domain/models.dart";
import "anthropic_client.dart";
import "llm_client.dart";
import "openai_client.dart";

/// An endpoint the registry can reach, and — where reaching it is not the
/// ordinary thing — how.
///
/// [build] is null for everything in `settings.json`, which is every endpoint
/// that is only a URL and a key. The one that is not is the server running on
/// this device: an ordinary OpenAI endpoint that may not be answering yet, so
/// it carries the client that waits for it.
///
/// Carried by the endpoint rather than decided by the registry, because the
/// alternative was comparing a provider id against a name the registry had to
/// be told was reserved — a special case in the one place that should know
/// nothing about who its endpoints are, and one more `==` arm for every
/// endpoint that ever needs decorating.
class LlmEndpoint {
  const LlmEndpoint(this.config, {this.build});

  final LlmProviderConfig config;

  final LlmClient Function(LlmProviderConfig config, String? apiKey)? build;
}

/// Turns the configured endpoints into clients, and answers what they can run.
/// Both inputs are read when used rather than captured: the settings page
/// edits them, and it does so long after this was built.
class LlmRegistry {
  LlmRegistry({required this.endpoints, required this.lookupEnv, this.lookupKey});

  final List<LlmEndpoint> Function() endpoints;

  /// One variable at a time, rather than a whole environment: the only use is
  /// finding a named key, and building a map of the process environment to
  /// answer that copies a hundred entries per lookup.
  final String? Function(String name) lookupEnv;

  /// The key stored for a provider id, or null for none — the store the
  /// settings page writes into, held by the OS where there is one. Configured
  /// before [lookupEnv]: a key pasted here wins over a named one, and is
  /// consulted after the config's own field, which is what an edit in flight
  /// still reads.
  final String? Function(String providerId)? lookupKey;

  final _clients = LlmClientCache();

  LlmEndpoint? endpointFor(String providerId) {
    for (final endpoint in endpoints()) {
      if (endpoint.config.id == providerId) return endpoint;
    }
    return null;
  }

  /// Null when nothing is configured under that name — the caller says so,
  /// rather than a request failing against a guessed endpoint.
  LlmClient? clientFor(String providerId) {
    final endpoint = endpointFor(providerId);
    return endpoint == null ? null : clientOf(endpoint);
  }

  /// For an endpoint already in hand. Callers that have just read the list use
  /// this rather than going back through [endpointFor], which would read and
  /// parse `settings.json` all over again.
  LlmClient clientOf(LlmEndpoint endpoint) {
    final config = endpoint.config;
    final key = resolveKeyFor(config);
    // A URL or key edited in settings has to reach the next turn, so a cached
    // client built from the old one is dropped rather than reused. The
    // on-device endpoint is the one this never rebuilds: its URL is empty and
    // stays empty, because the client behind it is a pool that routes per model
    // and outlives any one server's port.
    return _clients.of(
      config.id,
      "${config.api.name}|${config.baseUrl}|$key",
      () => (endpoint.build ?? _defaultBuild)(config, key),
    );
  }

  /// One order, decided once: the config's own field — the copy a dialog just
  /// returned — then the stored key, then the named environment variable. The
  /// registry builds clients from exactly this, so an edited stored key
  /// reaching the next turn is the cache signature above, not a second path.
  String? resolveKeyFor(LlmProviderConfig config) {
    if (config.apiKey.isNotEmpty) return config.apiKey;
    final stored = lookupKey?.call(config.id);
    if (stored != null && stored.isNotEmpty) return stored;
    return config.resolveKeyWith(lookupEnv);
  }

  /// Every model the configured endpoints offer. One that lists its own is
  /// taken at its word; otherwise it is asked — all of them at once, since one
  /// slow host should not hold up the rest, and one that cannot answer
  /// contributes nothing rather than failing the whole list.
  Future<List<ModelOption>> models() async {
    final configured = endpoints();
    final lists = await Future.wait(configured.map((e) =>
        e.config.models.isNotEmpty ? Future.value(e.config.models) : _listFrom(e)));
    return [
      for (var i = 0; i < configured.length; i++)
        for (final id in lists[i])
          ModelOption(
            providerId: configured[i].config.id,
            modelId: id,
            label: "${configured[i].config.displayName} · $id",
          ),
    ];
  }

  /// Bounded: an endpoint configured but unreachable — a stale localhost, a
  /// host that drops packets — would otherwise hold the model picker for the
  /// whole OS connect timeout.
  Future<List<String>> _listFrom(LlmEndpoint endpoint) async {
    try {
      return await clientOf(endpoint)
          .listModels()
          .timeout(const Duration(seconds: 10), onTimeout: () => const []);
    } catch (_) {
      return const [];
    }
  }

  void close() => _clients.close();

  /// What an endpoint gets when it names no builder of its own, which is every
  /// endpoint that is a URL and a key.
  static LlmClient _defaultBuild(LlmProviderConfig config, String? apiKey) =>
      switch (config.api) {
        LlmApi.anthropic =>
          AnthropicClient(baseUrl: Uri.parse(config.baseUrl), apiKey: apiKey),
        LlmApi.openai => OpenAiClient(baseUrl: Uri.parse(config.baseUrl), apiKey: apiKey),
      };
}
