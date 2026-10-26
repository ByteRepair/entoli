import "package:http/http.dart" as http;

import "../../../../domain/llm_provider.dart";
import "provider.dart";

/// The hosted providers that differ from the OpenAI shape by nothing but who
/// they are.

class GroqProvider extends OpenAiCompatibleProvider {
  const GroqProvider([super.config = preset]);

  static const preset = LlmProviderConfig(
    id: "groq",
    label: "Groq",
    api: LlmApi.openai,
    baseUrl: "https://api.groq.com/openai/v1",
    apiKeyEnv: "GROQ_API_KEY",
    defaultModelId: "openai/gpt-oss-120b",
    defaultLightModelId: "openai/gpt-oss-20b",
  );

  @override
  PresetTerms get terms => const PresetTerms(
        blurb: "Open models on fast hardware.",
        prompts: PromptUse.notTrained,
        policy: "https://groq.com/privacy-policy",
      );
}

class ZaiProvider extends OpenAiCompatibleProvider {
  const ZaiProvider([super.config = preset]);

  static const preset = LlmProviderConfig(
    id: "zai",
    label: "Z.ai",
    api: LlmApi.openai,
    baseUrl: "https://api.z.ai/api/paas/v4",
    apiKeyEnv: "ZAI_API_KEY",
    // The free ones, so the preset costs nothing until the user picks otherwise.
    defaultModelId: "glm-4.7-flash",
    defaultLightModelId: "glm-4.5-flash",
  );

  @override
  PresetTerms get terms => const PresetTerms(
        blurb: "GLM models, some of them free.",
        prompts: PromptUse.unstated,
        freeTier: "The GLM Flash models are free. Z.ai's terms do not say how "
            "prompts sent to the free models are handled, so treat them as not "
            "private.",
        policy: "https://docs.z.ai/legal-agreement/privacy-policy",
      );

  // shortcut: not known to keep a model list behind the key; the light
  // default is free, so the completion costs nothing.
  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) =>
      checkKeyByCompletion(apiKey, httpClient: httpClient);
}

class OllamaCloudProvider extends OpenAiCompatibleProvider {
  const OllamaCloudProvider([super.config = preset]);

  static const preset = LlmProviderConfig(
    id: "ollama-cloud",
    label: "Ollama Cloud",
    api: LlmApi.openai,
    // The same OpenAI-compatible surface the local server exposes, hosted.
    baseUrl: "https://ollama.com/v1",
    apiKeyEnv: "OLLAMA_API_KEY",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  );

  @override
  PresetTerms get terms => const PresetTerms(
        blurb: "Open models, hosted by Ollama.",
        prompts: PromptUse.notTrained,
        policy: "https://ollama.com/privacy",
      );

  // shortcut: not known to keep a model list behind the key.
  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) =>
      checkKeyByCompletion(apiKey, httpClient: httpClient);
}
