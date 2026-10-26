import "package:http/http.dart" as http;

import "../../../../domain/llm_provider.dart";
import "../gemini_client.dart";
import "../http_stream.dart";
import "../llm_client.dart";
import "provider.dart";

class GoogleProvider extends OpenAiCompatibleProvider {
  const GoogleProvider([super.config = preset]);

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

  @override
  PresetTerms get terms => const PresetTerms(
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
  LlmClient client(String? apiKey) => GeminiClient(baseUrl: baseUrl, apiKey: apiKey);

  /// Google answers a key it does not know with 400, not 401.
  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) => LlmProvider.askWith(
        http.Request("GET", under(baseUrl, "models"))
          ..headers["authorization"] = "Bearer $apiKey",
        httpClient: httpClient,
        rejecting: const {400, 401, 403},
      );
}
