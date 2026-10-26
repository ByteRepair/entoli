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

/// What a provider's terms say happens to the prompts sent to it.
enum PromptUse {
  /// Never leaves the machine.
  local,

  /// Not kept or trained on, by the provider's own terms.
  notTrained,

  /// Up to whichever upstream a request is routed to.
  dependsOnRoute,

  /// The free tier trains on prompts and may have them read by people; the
  /// paid tier does not.
  trainedWhenFree,

  /// The terms do not say for the free tier.
  unstated,
}

/// What the Add provider list says about a preset, beside its name. Held by the
/// provider's class rather than its config, so it is never written into
/// `settings.json` and a policy change is a release, not a migration.
class PresetTerms {
  const PresetTerms({
    required this.blurb,
    required this.prompts,
    this.freeTier,
    this.policy,
    this.keyUrl,
  });

  final String blurb;
  final PromptUse prompts;

  /// Non-null where the preset can be used for free and that comes at a cost
  /// to privacy: what the user is told, and must accept, before adding it.
  final String? freeTier;

  final String? policy;

  /// The provider's own page for making a key, null where none is needed.
  final String? keyUrl;
}
