import "../../../../domain/llm_provider.dart";
import "../../../../domain/model_info.dart";
import "../gemini_client.dart";
import "../openai_client.dart";
import "provider.dart";

class GoogleProvider extends OpenAiCompatibleProvider {
  const GoogleProvider([LlmProviderConfig config = preset])
    : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "google",
    name: "Google Gemini",
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
    freeTier:
        "On Google's free tier, your prompts and the replies are used "
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
      GeminiClient(baseUrl: baseUrl, apiKey: apiKey);

  /// What hears here is not what models.dev says transcribes. Its one Gemini
  /// that takes audio and writes text is a Live API model, which answers a
  /// socket rather than a request; while every Gemini text model hears audio
  /// in an ordinary request, which models.dev does not list. So the listening
  /// half is offered on those — not Live, not an embedding, not an image
  /// maker — and one models.dev does not describe is taken to hear, as any
  /// undescribed pick is taken to be what it was picked for.
  @override
  bool transcribes(String id, ModelInfo? info) =>
      !id.contains("-live") &&
      (info == null ||
          info.talks &&
              !info.makesImages &&
              id.startsWith("gemini-") &&
              !id.contains("embedding"));

  /// Google answers a key it does not know with 400, not 401.
  @override
  Set<int> get refusingStatuses => const {400, 401, 403};
}
