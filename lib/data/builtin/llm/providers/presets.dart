import "../../../../domain/llm_provider.dart";
import "anthropic.dart";
import "google.dart";
import "hosted.dart";
import "local_servers.dart";
import "openai.dart";
import "openrouter.dart";
import "provider.dart";

export "anthropic.dart";
export "google.dart";
export "hosted.dart";
export "local_servers.dart";
export "openai.dart";
export "openrouter.dart";
export "provider.dart";

/// Each preset's class, read with a config. The one list a new provider is
/// added to: the presets and [providerOf] are both built from it.
const _kinds = <LlmProvider Function([LlmProviderConfig])>[
  AnthropicProvider.new,
  OpenAiProvider.new,
  OpenRouterProvider.new,
  GroqProvider.new,
  GoogleProvider.new,
  ZaiProvider.new,
  OllamaCloudProvider.new,
  OllamaProvider.new,
  LmStudioProvider.new,
];

/// The endpoints worth offering by name, so configuring one is a key rather
/// than a URL nobody remembers. Not a whitelist: any OpenAI-compatible server
/// can be added by hand.
final llmProviderPresets = [for (final kind in _kinds) kind()];

/// The class [config] is read as. By host first, since a provider's quirks are
/// its server's and an entry renamed by hand still reaches them; then by
/// models.dev id, which is what a local server has; then by the wire format
/// alone.
LlmProvider providerOf(LlmProviderConfig config) {
  final kind = _kindOf(config);
  if (kind != null) return kind(config);
  return switch (config.api) {
    LlmApi.anthropic => AnthropicCompatibleProvider(config),
    LlmApi.openai => OpenAiCompatibleProvider(config),
  };
}

/// The preset [config] is an entry of, whatever it is called; null for an
/// endpoint typed in by hand.
LlmProvider? presetOf(LlmProviderConfig config) => _kindOf(config)?.call();

LlmProvider Function([LlmProviderConfig])? _kindOf(LlmProviderConfig config) =>
    _byHost[Uri.tryParse(config.baseUrl)?.host] ??
    _byCatalogId[config.catalogId];

/// A local server's host is anybody's, so it is read by models.dev id alone.
final _byHost = {
  for (final (i, p) in llmProviderPresets.indexed)
    if (p.needsKey) p.baseUrl.host: _kinds[i],
};

final _byCatalogId = {
  for (final (i, p) in llmProviderPresets.indexed)
    p.config.catalogId: _kinds[i],
};
