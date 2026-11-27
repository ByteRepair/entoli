import "../../../model/llm_provider.dart";
import "../mistral_client.dart";
import "provider.dart";

/// Mistral's API, which a Le Chat Pro or Team plan answers too: the key made
/// on Mistral Vibe's page draws on the plan's allowance, and past it on the
/// account's pay-as-you-go, the same key an API account makes.
class MistralProvider extends OpenAiCompatibleProvider with OfferedByName {
  const MistralProvider([LlmProviderConfig config = preset])
    : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "mistral",
    name: "Mistral",
    api: LlmApi.openai,
    baseUrl: "https://api.mistral.ai/v1",
    apiKeyEnv: "MISTRAL_API_KEY",
    defaultModelId: "mistral-large-latest",
    defaultLightModelId: "mistral-small-latest",
  );

  static const _terms = PresetTerms(
    maker: "Mistral",
    prompts: PromptUse.trainedWhenFree,
    freeTier:
        "On Mistral's free Experiment plan your prompts may be used to train "
        "its models. A paid plan, or a Le Chat Pro or Team key, is not used "
        "this way.",
    policy: "https://legal.mistral.ai/terms/privacy-policy",
    keyUrl: "https://chat.mistral.ai/code/extensions",
  );

  @override
  String get serviceName => "Mistral Le Chat";

  @override
  String get connectHint =>
      "Use your Le Chat plan, with a key from Mistral Vibe.";

  @override
  MistralClient client(String? apiKey) =>
      MistralClient(baseUrl: baseUrl, apiKey: apiKey);
}
