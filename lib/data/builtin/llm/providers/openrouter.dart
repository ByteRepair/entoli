import "../../../../domain/llm_provider.dart";
import "provider.dart";

class OpenRouterProvider extends OpenAiCompatibleProvider {
  const OpenRouterProvider([super.config = preset]);

  static const preset = LlmProviderConfig(
    id: "openrouter",
    label: "OpenRouter",
    api: LlmApi.openai,
    baseUrl: "https://openrouter.ai/api/v1",
    apiKeyEnv: "OPENROUTER_API_KEY",
    defaultModelId: "z-ai/glm-5.3-flash",
    defaultLightModelId: "nvidia/nemotron-3-nano-30b-a3b",
  );

  @override
  PresetTerms get terms => const PresetTerms(
        blurb: "One key for hundreds of models from many providers.",
        prompts: PromptUse.dependsOnRoute,
        policy: "https://openrouter.ai/privacy",
        keyUrl: "https://openrouter.ai/settings/keys",
      );

  @override
  String get imageModel => "google/gemini-2.5-flash-image";

  /// `/key` describes the key it is asked with; the model list is public.
  @override
  String get keyCheckPath => "key";
}
