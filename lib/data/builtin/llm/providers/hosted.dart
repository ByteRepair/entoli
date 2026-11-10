import "package:http/http.dart" as http;

import "../../../../domain/llm_provider.dart";
import "../../../../domain/provider_usage.dart";
import "../groq_client.dart";
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

  /// One that keeps what its replies say of the allowance: Groq says it on
  /// nothing else.
  @override
  GroqClient client(String? apiKey) =>
      GroqClient(baseUrl: baseUrl, apiKey: apiKey);
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
    with ChecksKeyByCompletion, OfferedByName {
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

  /// Ollama's compat layer reads an assistant's earlier thinking from
  /// `reasoning` and drops a field it does not know, so DeepSeek's name would
  /// arrive as nothing. Every model: the server puts it in the model's own
  /// template, which keeps it or leaves it out as the model was trained to.
  @override
  String? replayedReasoningField(String modelId) => "reasoning";

  static const _terms = PresetTerms(
    blurb: "Open models, hosted by Ollama.",
    prompts: PromptUse.notTrained,
    policy: "https://ollama.com/privacy",
    keyUrl: "https://ollama.com/settings/keys",
  );

  @override
  String get serviceName => "Ollama Cloud";

  @override
  String get connectHint => "Hosted open models, connected with an Ollama key.";

  /// `/api/balance`, documented: the plan's monthly credits and what was
  /// bought on top of them, both in dollars. A plan from before credits
  /// answers with its session and weekly limits in their place.
  @override
  Future<List<ProviderUsage>> usage(
    String? apiKey, {
    http.Client? httpClient,
  }) async => usageOf(
    await LlmProvider.getJson(
      baseUrl.resolve("/api/balance"),
      headers: authOf(apiKey),
      httpClient: httpClient,
    ),
  );

  /// [json], `/api/balance`'s answer, as what it says is spent and left. The
  /// included credits are an allowance; the purchased ones are a balance with
  /// none, left out when there are none, since most accounts never buy any.
  static List<ProviderUsage> usageOf(Map<String, dynamic> json) {
    final included = json["included"];
    final purchased = json["purchased"];
    return [
      if (included case {
        "balance_usd": final num left,
        "allowance_usd": final num allowance,
      })
        UsageWindow(
          label: "Monthly credits",
          used: (allowance - left).toDouble(),
          max: allowance.toDouble(),
          unit: UsageUnit.usd,
          resetsAt: _dateAt((included["period"] as Map?)?["until"]),
        )
      else if (included is Map<String, dynamic>)
        for (final (key, label) in const [
          ("session", "Session"),
          ("weekly", "Weekly"),
        ])
          if (included[key]
              case {"remaining_percent": final num remaining} && final limit)
            UsageWindow(
              label: label,
              used: (100 - remaining) / 100,
              max: 1,
              unit: UsageUnit.share,
              resetsAt: _dateAt(limit["resets_at"]),
            ),
      if (purchased case {"balance_usd": final num left} when left > 0)
        CreditBalance(label: "Purchased credits", usd: left.toDouble()),
    ];
  }

  static DateTime? _dateAt(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}
