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
/// preset id, which is what a local server has; then by the wire format alone.
LlmProvider providerOf(LlmProviderConfig config) {
  final host = Uri.tryParse(config.baseUrl)?.host;
  final kind = _byHost[host] ?? _byId[config.id];
  if (kind != null) return kind(config);
  return switch (config.api) {
    LlmApi.anthropic => AnthropicCompatibleProvider(config),
    LlmApi.openai => OpenAiCompatibleProvider(config),
  };
}

/// A local server's host is anybody's, so it is read by id alone.
final _byHost = {
  for (final (i, p) in llmProviderPresets.indexed)
    if (p.needsKey) p.baseUrl.host: _kinds[i],
};

final _byId = {for (final (i, p) in llmProviderPresets.indexed) p.id: _kinds[i]};
