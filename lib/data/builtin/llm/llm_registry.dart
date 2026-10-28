import "../../../core/log.dart";
import "../../../domain/llm_provider.dart";
import "../../../domain/models.dart";
import "llm_client.dart";
import "providers/provider.dart";

/// Turns the configured providers into clients, and answers what they can run.
/// Both inputs are read when used rather than captured: the settings page
/// edits them, and it does so long after this was built.
///
/// What a provider builds a client *with* is its own business: the on-device
/// server's "may not be answering yet" arrives as a provider class whose
/// client waits, without the registry knowing there is such a thing.
class LlmRegistry {
  LlmRegistry({
    required this.endpoints,
    required this.lookupEnv,
    required this.lookupKey,
  });

  final List<LlmProvider> Function() endpoints;

  /// One variable at a time, rather than a whole environment: the only use is
  /// finding a named key, and building a map of the process environment to
  /// answer that copies a hundred entries per lookup.
  final String? Function(String name) lookupEnv;

  /// The key stored for a provider id, or null for none — the store the
  /// settings page writes into, held by the OS where there is one. Asked
  /// before [lookupEnv]: a key pasted here wins over a named one.
  final String? Function(String providerId) lookupKey;

  final _clients = LlmClientCache();

  LlmProvider? providerFor(String providerId) {
    for (final provider in endpoints()) {
      if (provider.id == providerId) return provider;
    }
    return null;
  }

  /// Null when nothing is configured under that name — the caller says so,
  /// rather than a request failing against a guessed endpoint.
  LlmClient? clientFor(String providerId) {
    final provider = providerFor(providerId);
    return provider == null ? null : clientOf(provider);
  }

  /// For an endpoint already in hand. Callers that have just read the list use
  /// this rather than going back through [providerFor], which would read and
  /// parse `settings.json` all over again.
  LlmClient clientOf(LlmProvider provider) {
    final config = provider.config;
    final key = resolveKeyFor(config);
    // A URL or key edited in settings has to reach the next turn, so a cached
    // client built from the old one is dropped rather than reused. The
    // on-device endpoint is the one this never rebuilds: its URL is empty and
    // stays empty, because the client behind it is a pool that routes per model
    // and outlives any one server's port.
    return _clients.of(
      config.id,
      "${config.api.name}|${config.baseUrl}|$key",
      () => provider.client(key),
    );
  }

  /// One order, decided once: the stored key, then the named environment
  /// variable. The registry builds clients from exactly this, so an edited
  /// stored key reaching the next turn is the cache signature above, not a
  /// second path.
  String? resolveKeyFor(LlmProviderConfig config) {
    final stored = lookupKey(config.id);
    if (stored != null && stored.isNotEmpty) return stored;
    return config.resolveKeyWith(lookupEnv);
  }

  /// Every model the configured endpoints list beyond models.dev's. All asked
  /// at once, since one slow host should not hold up the rest, and one that
  /// cannot answer contributes nothing rather than failing the whole list.
  Future<List<ModelOption>> models() async {
    final configured = endpoints();
    final lists = await Future.wait(configured.map(_listFrom));
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
  Future<List<String>> _listFrom(LlmProvider provider) async {
    try {
      return await provider
          .listModels(resolveKeyFor(provider.config))
          .timeout(const Duration(seconds: 10), onTimeout: () => const []);
    } catch (e) {
      logFailure("llm", "listing ${provider.id}'s models failed", e);
      return const [];
    }
  }

  void close() => _clients.close();
}
