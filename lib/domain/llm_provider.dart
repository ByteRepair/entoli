import "model_info.dart";

/// Which wire format a provider speaks. Everything that copied OpenAI's
/// `/chat/completions` is [openai]; Anthropic's `/messages` is its own.
enum LlmApi { openai, anthropic }

/// An endpoint the agent can call, as the user configured it. Held in
/// `settings.json` rather than guessed from environment variables: the same
/// key reaches half a dozen gateways, and only the base URL says which one.
/// The key itself is not here — it is stored per id in the secret store
/// (`AppSecrets`), or named by [apiKeyEnv] and read from the environment.
class LlmProviderConfig {
  const LlmProviderConfig({
    required this.id,
    required this.api,
    required this.baseUrl,
    this.label,
    this.apiKeyEnv,
    this.models = const [],
    this.defaultModelId,
    this.defaultLightModelId,
    this.customModels = const [],
  });

  final String id;
  final LlmApi api;

  /// The versioned root, e.g. `https://api.openai.com/v1`. Paths are appended
  /// to it, so a gateway that lives under a prefix works unchanged.
  final String baseUrl;

  final String? label;

  final String? apiKeyEnv;

  /// What to offer in the model picker. Empty asks the endpoint, which most
  /// of them answer and a few do not.
  final List<String> models;

  /// The model a new chat is answered by when the user picks this provider's
  /// "Default" entry, and the one the title, memory and classifier pickers
  /// resolve to through [defaultLightModelId] when theirs is unset. Null means
  /// the provider names no recommendation: picking Default there has nothing
  /// to resolve to, which reads as None.
  final String? defaultModelId;

  /// The light model behind the title, memory and classifier roles.
  final String? defaultLightModelId;

  /// Models the user described by hand, for what models.dev does not list —
  /// a fine-tune, a private deployment. Ahead of the catalog's on a clash.
  final List<ModelInfo> customModels;

  String get displayName => label ?? id;

  /// [lookup] reads the app's own environment and whatever settings adds, so a
  /// key can be named there instead of pasted here.
  String? resolveKeyWith(String? Function(String name) lookup) {
    final name = apiKeyEnv;
    if (name == null) return null;
    final value = lookup(name);
    return (value == null || value.isEmpty) ? null : value;
  }

  String? resolveKey(Map<String, String> environment) =>
      resolveKeyWith((name) => environment[name]);

  /// Which field a role's `Default` entry resolves to: the chat default for
  /// the LLM field, the light one for title, memory and classifier. Named
  /// here so every picker, and the backend's null-model resolution, read the
  /// same two rules rather than spelling them as lambdas at each site.
  static String? chatDefaultOf(LlmProviderConfig config) => config.defaultModelId;

  static String? lightDefaultOf(LlmProviderConfig config) =>
      config.defaultLightModelId;

  /// Keyed by preset id rather than stored on the config, so a provider added
  /// before image generation existed gets one too. Only the presets whose API
  /// answers an image request are here.
  static String? imageDefaultOf(LlmProviderConfig config) => const {
        "openai": "gpt-image-1",
        "openrouter": "google/gemini-2.5-flash-image",
      }[config.id];

  LlmProviderConfig copyWith({
    String? id,
    LlmApi? api,
    String? baseUrl,
    String? label,
    String? apiKeyEnv,
    List<String>? models,
    String? defaultModelId,
    String? defaultLightModelId,
    List<ModelInfo>? customModels,
  }) =>
      LlmProviderConfig(
        id: id ?? this.id,
        api: api ?? this.api,
        baseUrl: baseUrl ?? this.baseUrl,
        label: label ?? this.label,
        apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
        models: models ?? this.models,
        defaultModelId: defaultModelId ?? this.defaultModelId,
        defaultLightModelId: defaultLightModelId ?? this.defaultLightModelId,
        customModels: customModels ?? this.customModels,
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "api": api.name,
        "baseUrl": baseUrl,
        if (label != null) "label": label,
        if (apiKeyEnv != null) "apiKeyEnv": apiKeyEnv,
        if (models.isNotEmpty) "models": models,
        if (defaultModelId != null) "defaultModelId": defaultModelId,
        if (defaultLightModelId != null) "defaultLightModelId": defaultLightModelId,
        if (customModels.isNotEmpty)
          "customModels": {for (final m in customModels) m.id: m.toJson()},
      };

  /// Null for anything that does not name an id and a base URL: a half-written
  /// entry is worse than a missing one, because it fails at the first prompt.
  static LlmProviderConfig? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value["id"];
    final baseUrl = value["baseUrl"];
    if (id is! String || id.isEmpty || baseUrl is! String || baseUrl.isEmpty) return null;
    final models = value["models"];
    final custom = value["customModels"];
    return LlmProviderConfig(
      id: id,
      api: value["api"] == "anthropic" ? LlmApi.anthropic : LlmApi.openai,
      baseUrl: baseUrl,
      label: value["label"] as String?,
      // An older file's `apiKey` is ignored: the store is where a key lives,
      // and a key left in the file was stripped by the save that followed it.
      apiKeyEnv: value["apiKeyEnv"] as String?,
      models: models is List ? models.whereType<String>().toList() : const [],
      defaultModelId: value["defaultModelId"] as String?,
      defaultLightModelId: value["defaultLightModelId"] as String?,
      customModels: [
        if (custom is Map)
          for (final MapEntry(:key, :value) in custom.entries)
            if (key is String && value is Map) ModelInfo.fromJson(key, value),
      ],
    );
  }
}

/// The endpoints worth offering by name, so configuring one is a key rather
/// than a URL nobody remembers. Not a whitelist: any OpenAI-compatible server
/// can be added by hand.
const llmProviderPresets = <LlmProviderConfig>[
  LlmProviderConfig(
    id: "anthropic",
    label: "Anthropic",
    api: LlmApi.anthropic,
    baseUrl: "https://api.anthropic.com/v1",
    apiKeyEnv: "ANTHROPIC_API_KEY",
    defaultModelId: "claude-sonnet-5",
    defaultLightModelId: "claude-haiku-4-5",
  ),
  LlmProviderConfig(
    id: "openai",
    label: "OpenAI",
    api: LlmApi.openai,
    baseUrl: "https://api.openai.com/v1",
    apiKeyEnv: "OPENAI_API_KEY",
    defaultModelId: "gpt-5.6-terra",
    defaultLightModelId: "gpt-5.6-luna",
  ),
  LlmProviderConfig(
    id: "openrouter",
    label: "OpenRouter",
    api: LlmApi.openai,
    baseUrl: "https://openrouter.ai/api/v1",
    apiKeyEnv: "OPENROUTER_API_KEY",
    defaultModelId: "z-ai/glm-5.3-flash",
    defaultLightModelId: "nvidia/nemotron-3-nano-30b-a3b",
  ),
  LlmProviderConfig(
    id: "groq",
    label: "Groq",
    api: LlmApi.openai,
    baseUrl: "https://api.groq.com/openai/v1",
    apiKeyEnv: "GROQ_API_KEY",
    defaultModelId: "openai/gpt-oss-120b",
    defaultLightModelId: "openai/gpt-oss-20b",
  ),
  LlmProviderConfig(
    id: "ollama-cloud",
    label: "Ollama Cloud",
    api: LlmApi.openai,
    // The same OpenAI-compatible surface the local server exposes, hosted.
    baseUrl: "https://ollama.com/v1",
    apiKeyEnv: "OLLAMA_API_KEY",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  ),
  LlmProviderConfig(
    id: "ollama",
    label: "Ollama (local)",
    api: LlmApi.openai,
    baseUrl: "http://localhost:11434/v1",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  ),
  LlmProviderConfig(
    id: "lmstudio",
    label: "LM Studio (local)",
    api: LlmApi.openai,
    baseUrl: "http://localhost:1234/v1",
    defaultModelId: "glm-5.3-flash",
    defaultLightModelId: "nemotron-3-nano:30b",
  ),
];
