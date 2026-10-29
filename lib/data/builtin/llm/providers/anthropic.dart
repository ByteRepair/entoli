import "package:http/http.dart" as http;

import "../../../../domain/llm_provider.dart";
import "../anthropic_client.dart";
import "../http_stream.dart";
import "../llm_client.dart";
import "provider.dart";

/// Anything that speaks Anthropic's `/messages`: Anthropic itself, and a
/// gateway in front of it. Anthropic makes no images and has no audio
/// endpoints.
class AnthropicCompatibleProvider extends LlmProvider {
  const AnthropicCompatibleProvider(super.config, [super.terms]);

  @override
  bool get takesPdfs => true;

  @override
  LlmClient client(String? apiKey) => AnthropicClient(baseUrl: baseUrl, apiKey: apiKey);

  @override
  Map<String, String> authOf(String? apiKey) => AnthropicClient.authOf(apiKey);

  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) => LlmProvider.askWith(
        http.Request("GET", under(baseUrl, "models"))
          ..headers.addAll(authOf(apiKey)),
        httpClient: httpClient,
      );
}

class AnthropicProvider extends AnthropicCompatibleProvider {
  const AnthropicProvider([LlmProviderConfig config = preset]) : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "anthropic",
    name: "Anthropic",
    api: LlmApi.anthropic,
    baseUrl: "https://api.anthropic.com/v1",
    apiKeyEnv: "ANTHROPIC_API_KEY",
    defaultModelId: "claude-sonnet-5",
    defaultLightModelId: "claude-haiku-4-5",
  );

  static const _terms = PresetTerms(
    blurb: "Claude models.",
    prompts: PromptUse.notTrained,
    policy: "https://www.anthropic.com/legal/commercial-terms",
    keyUrl: "https://platform.claude.com/settings/keys",
  );
}
