import "../../../../domain/llm_provider.dart";
import "provider.dart";

/// The hosted providers that differ from the OpenAI shape by nothing but who
/// they are.

class GroqProvider extends OpenAiCompatibleProvider {
  const GroqProvider([LlmProviderConfig config = preset]) : super(config, _terms);

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
}

// shortcut: not known to keep a model list behind the key; its light default
// is free, so the completion costs nothing.
class ZaiProvider extends OpenAiCompatibleProvider with ChecksKeyByCompletion {
  const ZaiProvider([LlmProviderConfig config = preset]) : super(config, _terms);

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
    freeTier: "The GLM Flash models are free. Z.ai's terms do not say how "
        "prompts sent to the free models are handled, so treat them as not "
        "private.",
    policy: "https://docs.z.ai/legal-agreement/privacy-policy",
    keyUrl: "https://z.ai/manage-apikey/apikey-list",
  );
}

// shortcut: not known to keep a model list behind the key.
class OllamaCloudProvider extends OpenAiCompatibleProvider with ChecksKeyByCompletion {
  const OllamaCloudProvider([LlmProviderConfig config = preset]) : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "ollama-cloud",
    name: "Ollama Cloud",
    api: LlmApi.openai,
    // The same OpenAI-compatible surface the local server exposes, hosted.
    baseUrl: "https://ollama.com/v1",
    apiKeyEnv: "OLLAMA_API_KEY",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  );

  static const _terms = PresetTerms(
    blurb: "Open models, hosted by Ollama.",
    prompts: PromptUse.notTrained,
    policy: "https://ollama.com/privacy",
    keyUrl: "https://ollama.com/settings/keys",
  );
}
