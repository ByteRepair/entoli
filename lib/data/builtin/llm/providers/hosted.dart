import "package:http/http.dart" as http;

import "../../../../domain/llm_provider.dart";
import "../../../../domain/provider_usage.dart";
import "../groq_client.dart";
import "../llm_client.dart";
import "provider.dart";

/// The hosted providers that differ from the OpenAI shape by nothing but who
/// they are.

class GroqProvider extends OpenAiCompatibleProvider {
  const GroqProvider([LlmProviderConfig config = preset])
    : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "groq",
    name: "Groq",
    api: LlmApi.openai,
    baseUrl: "https://api.groq.com/openai/v1",
    apiKeyEnv: "GROQ_API_KEY",
    defaultModelId: "openai/gpt-oss-120b",
    defaultLightModelId: "openai/gpt-oss-20b",
  );

  static const _terms = PresetTerms(
    blurb: "Open models on fast hardware.",
    prompts: PromptUse.notTrained,
    policy: "https://groq.com/privacy-policy",
    keyUrl: "https://console.groq.com/keys",
  );

  @override
  GroqClient client(String? apiKey) =>
      GroqClient(baseUrl: baseUrl, apiKey: apiKey);

  /// What the last reply said: Groq says it on nothing else.
  @override
  Future<List<UsageWindow>> usage(
    LlmClient client,
    String? apiKey, {
    http.Client? httpClient,
  }) async => client is GroqClient ? client.usage : const [];
}

// shortcut: not known to keep a model list behind the key; its light default
// is free, so the completion costs nothing.
class ZaiProvider extends OpenAiCompatibleProvider with ChecksKeyByCompletion {
  const ZaiProvider([LlmProviderConfig config = preset])
    : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "zai",
    name: "Z.ai",
    api: LlmApi.openai,
    baseUrl: "https://api.z.ai/api/paas/v4",
    apiKeyEnv: "ZAI_API_KEY",
    // The free ones, so the preset costs nothing until the user picks otherwise.
    defaultModelId: "glm-4.7-flash",
    defaultLightModelId: "glm-4.5-flash",
  );

  static const _terms = PresetTerms(
    blurb: "GLM models, some of them free.",
    prompts: PromptUse.unstated,
    freeTier:
        "The GLM Flash models are free. Z.ai's terms do not say how "
        "prompts sent to the free models are handled, so treat them as not "
        "private.",
    policy: "https://docs.z.ai/legal-agreement/privacy-policy",
    keyUrl: "https://z.ai/manage-apikey/apikey-list",
  );
}

// shortcut: not known to keep a model list behind the key.
class OllamaCloudProvider extends OpenAiCompatibleProvider
    with ChecksKeyByCompletion {
  const OllamaCloudProvider([LlmProviderConfig config = preset])
    : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "ollama-cloud",
    name: "Ollama Cloud",
    api: LlmApi.openai,
    // The same OpenAI-compatible surface the local server exposes, hosted.
    baseUrl: "https://ollama.com/v1",
    apiKeyEnv: "OLLAMA_API_KEY",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "gemma4:31b",
  );

  static const _terms = PresetTerms(
    blurb: "Open models, hosted by Ollama.",
    prompts: PromptUse.notTrained,
    policy: "https://ollama.com/privacy",
    keyUrl: "https://ollama.com/settings/keys",
  );

  /// `/api/usage`, the endpoint ollama.com's own settings page reads. Not
  /// documented: it has answered with a `limits` object holding the session
  /// and weekly allowances as fractions, and since October 2026 without it,
  /// which is nothing to show rather than a failure.
  @override
  Future<List<UsageWindow>> usage(
    LlmClient client,
    String? apiKey, {
    http.Client? httpClient,
  }) async => usageOf(
    await LlmProvider.getJson(
      baseUrl.resolve("/api/usage"),
      headers: authOf(apiKey),
      httpClient: httpClient,
    ),
  );

  /// [json], `/api/usage`'s answer, as the allowances it names.
  static List<UsageWindow> usageOf(Map<String, dynamic> json) {
    final limits = json["limits"];
    if (limits is! Map<String, dynamic>) return const [];
    return [
      for (final (key, label) in const [
        ("session", "Session"),
        ("weekly", "Weekly"),
      ])
        if (limits[key] case {"usage": final num used})
          UsageWindow(
            label: label,
            used: used.toDouble(),
            max: 1,
            unit: UsageUnit.share,
          ),
    ];
  }
}
