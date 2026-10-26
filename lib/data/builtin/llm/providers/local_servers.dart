import "package:http/http.dart" as http;

import "../../../../domain/llm_provider.dart";
import "provider.dart";

/// A model server the user runs on this machine. Nothing there checks a key,
/// so any key is a yes.
abstract class LocalServerProvider extends OpenAiCompatibleProvider {
  const LocalServerProvider(super.config);

  @override
  Future<bool> checkKey(String apiKey, {http.Client? httpClient}) async => true;
}

class OllamaProvider extends LocalServerProvider {
  const OllamaProvider([super.config = preset]);

  static const preset = LlmProviderConfig(
    id: "ollama",
    label: "Ollama (local)",
    api: LlmApi.openai,
    baseUrl: "http://localhost:11434/v1",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  );

  @override
  PresetTerms get terms => const PresetTerms(
        blurb: "Models you run yourself with Ollama.",
        prompts: PromptUse.local,
      );
}

class LmStudioProvider extends LocalServerProvider {
  const LmStudioProvider([super.config = preset]);

  static const preset = LlmProviderConfig(
    id: "lmstudio",
    label: "LM Studio (local)",
    api: LlmApi.openai,
    baseUrl: "http://localhost:1234/v1",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  );

  @override
  PresetTerms get terms => const PresetTerms(
        blurb: "Models you run yourself with LM Studio.",
        prompts: PromptUse.local,
      );
}
