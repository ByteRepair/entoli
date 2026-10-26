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

/// The endpoints worth offering by name, so configuring one is a key rather
/// than a URL nobody remembers. Not a whitelist: any OpenAI-compatible server
/// can be added by hand.
const llmProviderPresets = <LlmProvider>[
  AnthropicProvider(),
  OpenAiProvider(),
  OpenRouterProvider(),
  GroqProvider(),
  GoogleProvider(),
  ZaiProvider(),
  OllamaCloudProvider(),
  OllamaProvider(),
  LmStudioProvider(),
];

/// The class [config] is read as. By host first, since a provider's quirks are
/// its server's and an entry renamed by hand still reaches them; then by
/// preset id, which is what a local server has; then by the wire format alone.
LlmProvider providerOf(LlmProviderConfig config) {
  final host = Uri.tryParse(config.baseUrl)?.host;
  final build = _byHost[host] ?? _byId[config.id];
  if (build != null) return build(config);
  return switch (config.api) {
    LlmApi.anthropic => AnthropicCompatibleProvider(config),
    LlmApi.openai => OpenAiCompatibleProvider(config),
  };
}

final _byHost = <String, LlmProvider Function(LlmProviderConfig)>{
  "api.anthropic.com": AnthropicProvider.new,
  "api.openai.com": OpenAiProvider.new,
  "openrouter.ai": OpenRouterProvider.new,
  "api.groq.com": GroqProvider.new,
  "generativelanguage.googleapis.com": GoogleProvider.new,
  "api.z.ai": ZaiProvider.new,
  "ollama.com": OllamaCloudProvider.new,
};

final _byId = <String, LlmProvider Function(LlmProviderConfig)>{
  AnthropicProvider.preset.id: AnthropicProvider.new,
  OpenAiProvider.preset.id: OpenAiProvider.new,
  OpenRouterProvider.preset.id: OpenRouterProvider.new,
  GroqProvider.preset.id: GroqProvider.new,
  GoogleProvider.preset.id: GoogleProvider.new,
  ZaiProvider.preset.id: ZaiProvider.new,
  OllamaCloudProvider.preset.id: OllamaCloudProvider.new,
  OllamaProvider.preset.id: OllamaProvider.new,
  LmStudioProvider.preset.id: LmStudioProvider.new,
};
