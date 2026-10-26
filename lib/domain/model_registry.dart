import "dart:convert";

import "package:flutter/foundation.dart" show ValueNotifier;

import "local_model.dart";
import "llm_provider.dart";
import "model_info.dart";

export "model_info.dart";

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

  /// models.dev's entry for [provider]: the same id, or failing that the same
  /// base URL. Which of them a provider offers is its class's to decide — see
  /// `LlmProvider.models`.
  Map<String, ModelInfo>? entryOf(LlmProviderConfig provider) =>
      _providers[provider.id] ?? _providers[_apis[_normalUrl(provider.baseUrl)]];

  ModelInfo? lookup(LlmProviderConfig provider, String model) =>
      provider.customModels.where((m) => m.id == model).firstOrNull ??
      entryOf(provider)?[model];

  /// This catalog, as fetched from models.dev at [at].
  ModelCatalog fetchedAt(DateTime at) => ModelCatalog._(_providers, _apis, at);

  /// The same file with only the fields [ModelInfo] reads, for the cache.
  String toJsonText() {
    final apiOf = {for (final e in _apis.entries) e.value: e.key};
    return jsonEncode({
      fetchedKey: ?fetched?.toIso8601String(),
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
/// known, which every reader treats as "images pass, the global context guess".
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
