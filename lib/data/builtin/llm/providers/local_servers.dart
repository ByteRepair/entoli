import "../../../../domain/llm_provider.dart";
import "provider.dart";

/// A model server the user runs on this machine. Nothing there checks a key,
/// so any key is a yes.
abstract class LocalServerProvider extends OpenAiCompatibleProvider with KeyFree {
  const LocalServerProvider(super.config, [super.terms]);
}

class OllamaProvider extends LocalServerProvider {
  const OllamaProvider([LlmProviderConfig config = preset]) : super(config, _terms);

  static const preset = LlmProviderConfig(
    id: "ollama",
    label: "Ollama (local)",
    api: LlmApi.openai,
    baseUrl: "http://localhost:11434/v1",
    modelsEndpoint: "http://localhost:11434/v1/models",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  );

  static const _terms = PresetTerms(
    blurb: "Models you run yourself with Ollama.",
    prompts: PromptUse.local,
  );
}

class LmStudioProvider extends LocalServerProvider {
  const LmStudioProvider([LlmProviderConfig config = preset]) : super(config, _terms);

  static const preset = LlmProviderConfig(
    id: "lmstudio",
    label: "LM Studio (local)",
    api: LlmApi.openai,
    baseUrl: "http://localhost:1234/v1",
    modelsEndpoint: "http://localhost:1234/v1/models",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  );

  static const _terms = PresetTerms(
    blurb: "Models you run yourself with LM Studio.",
    prompts: PromptUse.local,
  );
}
