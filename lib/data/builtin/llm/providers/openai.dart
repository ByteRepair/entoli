import "../../../../domain/llm_provider.dart";
import "provider.dart";

class OpenAiProvider extends OpenAiCompatibleProvider {
  const OpenAiProvider([LlmProviderConfig config = preset]) : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "openai",
    name: "OpenAI",
    api: LlmApi.openai,
    baseUrl: "https://api.openai.com/v1",
    apiKeyEnv: "OPENAI_API_KEY",
    defaultModelId: "gpt-5.6-terra",
    defaultLightModelId: "gpt-5.6-luna",
  );

  static const _terms = PresetTerms(
    blurb: "GPT models, and gpt-image for pictures.",
    prompts: PromptUse.notTrained,
    policy: "https://openai.com/enterprise-privacy",
    keyUrl: "https://platform.openai.com/api-keys",
  );

  /// As a `file` part, which OpenAI's own `/chat/completions` takes.
  @override
  bool get takesPdfs => true;

  @override
  String get imageModel => "gpt-image-1";
}
