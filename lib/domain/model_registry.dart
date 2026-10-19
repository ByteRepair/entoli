import "dart:convert";

import "package:flutter/foundation.dart" show ValueNotifier;

import "local_model.dart";
import "llm_provider.dart";

/// What the app knows of one model: the fields of models.dev it reads, in
/// models.dev's own JSON shape, which is also how a model the user adds by
/// hand is stored.
class ModelInfo {
  const ModelInfo({
    required this.id,
    this.name,
    this.readsImages = false,
    this.makesImages = false,
    this.context,
    this.output,
    this.reasoning = false,
    this.toolCall = false,
    this.talks = true,
    this.inputCost,
    this.outputCost,
  });

  factory ModelInfo.fromJson(String id, Map json) {
    final modalities = json["modalities"];
    // A side not named is text, the ordinary case.
    bool has(String side, String kind) =>
        (modalities is Map ? modalities[side] as List? : null)?.contains(kind) ??
        kind == "text";
    final limit = json["limit"] is Map ? json["limit"] as Map : const {};
    final cost = json["cost"] is Map ? json["cost"] as Map : const {};
    // models.dev writes 0 for a model with no window to speak of (an image
    // model), which is no answer rather than a window of nothing.
    int? positive(Object? n) => n is num && n > 0 ? n.toInt() : null;
    double? price(Object? n) => n is num ? n.toDouble() : null;
    return ModelInfo(
      id: id,
      name: json["name"] is String ? json["name"] as String : null,
      readsImages: has("input", "image"),
      makesImages: has("output", "image"),
      talks: has("input", "text") && has("output", "text"),
      context: positive(limit["context"]),
      output: positive(limit["output"]),
      reasoning: json["reasoning"] == true,
      toolCall: json["tool_call"] == true,
      inputCost: price(cost["input"]),
      outputCost: price(cost["output"]),
    );
  }

  final String id;
  final String? name;

  /// Whether an image may be sent to it. False is also the answer for a model
  /// nobody knows, since an image a model cannot take fails the whole request.
  final bool readsImages;
  final bool makesImages;

  /// The context window in tokens, null where unknown — read as
  /// `AppSettings.totalContext`, the app-wide guess.
  final int? context;
  final int? output;
  final bool reasoning;
  final bool toolCall;

  /// Takes text in and gives text out: a chat model, rather than a speech,
  /// transcription or image-only one.
  final bool talks;

  /// US dollars per million tokens.
  final double? inputCost;
  final double? outputCost;

  String get displayName => name ?? id;

  /// What the agent needs of a model that answers turns: it works through
  /// tools. The background roles — title, classifier, memory — need only
  /// [talks].
  bool get answersTurns => talks && toolCall;

  Map<String, dynamic> toJson() => {
        if (name != null) "name": name,
        "reasoning": reasoning,
        "tool_call": toolCall,
        "modalities": {
          "input": [if (talks) "text", if (readsImages) "image"],
          "output": [if (talks) "text", if (makesImages) "image"],
        },
        "limit": {"context": ?context, "output": ?output},
        if (inputCost != null || outputCost != null)
          "cost": {"input": ?inputCost, "output": ?outputCost},
      };
}

/// models.dev (`https://models.dev/api.json`), or the trimmed copy of it the
/// app keeps: the same shape with only the fields [ModelInfo] reads.
///
/// A model is looked up exactly, inside the models.dev provider a configured
/// one is: the same id, or failing that the same base URL. A model several
/// hosts serve differs between them, so nothing is guessed across providers.
/// A provider's own [LlmProviderConfig.customModels] come first.
class ModelCatalog {
  ModelCatalog._(this._providers, this._apis, [this.fetched]);

  /// Anything that is not models.dev's shape is skipped entry by entry rather
  /// than failing the catalog.
  factory ModelCatalog.parse(String text) {
    final providers = <String, Map<String, ModelInfo>>{};
    final apis = <String, String>{};
    final json = jsonDecode(text);
    if (json is! Map) return empty;
    for (final MapEntry(key: id, value: provider) in json.entries) {
      if (id is! String || provider is! Map) continue;
      final api = provider["api"];
      if (api is String) apis[_normalUrl(api)] = id;
      final models = provider["models"];
      if (models is! Map) continue;
      providers[id] = {
        for (final MapEntry(key: model, value: info) in models.entries)
          if (model is String && info is Map) model: ModelInfo.fromJson(model, info),
      };
    }
    return ModelCatalog._(
        providers, apis, DateTime.tryParse("${json[fetchedKey] ?? ""}"));
  }

  /// When the copy this was read from came from models.dev. Null for the
  /// built-in defaults, which is all a picker offers until a fetch lands.
  final DateTime? fetched;

  /// Beside the providers in the cached file: the parse skips a key whose
  /// value is not a provider.
  static const fetchedKey = "_fetched";

  static final empty = ModelCatalog._(const {}, const {});

  /// What every lookup reads. A notifier because the readers are synchronous
  /// and some have no container to ask — the projection's gate, the context
  /// bar — while the picker redraws when a fetch lands.
  static final notifier = ValueNotifier<ModelCatalog>(empty);
  static ModelCatalog get current => notifier.value;

  final Map<String, Map<String, ModelInfo>> _providers;
  final Map<String, String> _apis;

  Map<String, ModelInfo>? _of(LlmProviderConfig provider) =>
      _providers[provider.id] ?? _providers[_apis[_normalUrl(provider.baseUrl)]];

  ModelInfo? lookup(LlmProviderConfig provider, String model) =>
      provider.customModels.where((m) => m.id == model).firstOrNull ??
      _of(provider)?[model];

  /// Every model [provider] offers: its own, then the catalog's.
  List<ModelInfo> modelsOf(LlmProviderConfig provider) {
    final own = {for (final m in provider.customModels) m.id: m};
    return [...own.values, ...?_of(provider)?.values.where((m) => !own.containsKey(m.id))];
  }

  /// The same file with only the fields [ModelInfo] reads, for the cache.
  String toJsonText({Map<String, Object?> extra = const {}}) {
    final apiOf = {for (final e in _apis.entries) e.value: e.key};
    return jsonEncode({
      ...extra,
      for (final MapEntry(key: id, value: models) in _providers.entries)
        id: {
          "api": ?apiOf[id],
          "models": {for (final m in models.values) m.id: m.toJson()},
        },
    });
  }

  static String _normalUrl(String url) =>
      url.endsWith("/") ? url.substring(0, url.length - 1) : url;
}

/// What the app knows of [modelId] at [provider]: the on-device models, kept
/// here by hand, then the provider's own and models.dev. Null where nothing is
/// known, which every reader treats as "no images, the global context guess".
///
/// The Apple on-device model: `SystemLanguageModel.contextSize` reads 8,192
/// on the OS today, and the framework only exposes it from 26.4 on — one
/// constant here is what that is while the reader is the compaction
/// machinery, which cannot wait on a channel round trip. The provider's MLX
/// rows are other models whose windows are their own; a null model id is the
/// provider's default — the system model.
ModelInfo? modelInfoOf(LlmProviderConfig? provider, String? modelId) {
  if (provider == null) return null;
  if (provider.id == appleProviderId) {
    return modelId == null || modelId == appleModelId
        ? const ModelInfo(id: appleModelId, context: 8192)
        : null;
  }
  return modelId == null ? null : ModelCatalog.current.lookup(provider, modelId);
}
