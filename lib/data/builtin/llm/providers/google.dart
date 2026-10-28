import "../../../../domain/llm_provider.dart";
import "../gemini_client.dart";
import "../openai_client.dart";
import "provider.dart";

class GoogleProvider extends OpenAiCompatibleProvider {
  const GoogleProvider([LlmProviderConfig config = preset]) : super(config, _terms);

  static const preset = LlmProviderConfig(
    id: "google",
    label: "Google Gemini",
    api: LlmApi.openai,
    // Gemini's OpenAI-compatible surface, not its native one.
    baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
    apiKeyEnv: "GEMINI_API_KEY",
    // Lite for both: the free tier refuses Flash.
    defaultModelId: "gemini-flash-lite-latest",
    defaultLightModelId: "gemini-flash-lite-latest",
  );

  static const _terms = PresetTerms(
    blurb: "Gemini models, with a free tier.",
    prompts: PromptUse.trainedWhenFree,
    freeTier: "On Google's free tier, your prompts and the replies are used "
        "to improve Google's products, and people at Google may read them. "
        "Do not send anything private, confidential or personal. A key with "
        "billing turned on is not used this way.",
    policy: "https://ai.google.dev/gemini-api/terms",
    keyUrl: "https://aistudio.google.com/apikey",
  );

  @override
  Set<String> get retiredModels => const {"gemini-2.5-flash"};

  @override
  OpenAiClient client(String? apiKey) =>
      GeminiClient(baseUrl: baseUrl, apiKey: apiKey, modelsUrl: modelsUrl);

  /// Google answers a key it does not know with 400, not 401.
  @override
  Set<int> get refusingStatuses => const {400, 401, 403};
}
