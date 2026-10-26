import "../../../../domain/llm_provider.dart";
import "provider.dart";

class OpenAiProvider extends OpenAiCompatibleProvider {
  const OpenAiProvider([super.config = preset]);

  static const preset = LlmProviderConfig(
    id: "openai",
    label: "OpenAI",
    api: LlmApi.openai,
    baseUrl: "https://api.openai.com/v1",
    apiKeyEnv: "OPENAI_API_KEY",
    defaultModelId: "gpt-5.6-terra",
    defaultLightModelId: "gpt-5.6-luna",
  );

  @override
  PresetTerms get terms => const PresetTerms(
        blurb: "GPT models, and gpt-image for pictures.",
        prompts: PromptUse.notTrained,
        policy: "https://openai.com/enterprise-privacy",
      );

  /// As a `file` part, which OpenAI's own `/chat/completions` takes.
  @override
  bool get takesPdfs => true;

  @override
  String get imageModel => "gpt-image-1";
}
