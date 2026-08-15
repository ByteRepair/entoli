import "dart:convert";

import "../core/config.dart";
import "llm_provider.dart";
import "models.dart";

/// Persisted app-level settings (default model for new chats, etc.).
class AppSettings {
  AppSettings({
    this.defaultModelId,
    this.defaultProviderId,
    this.opencodeEnv = const {},
    this.defaultBackend,
    this.approveCommands = true,
    this.llmProviders = const [],
  });

  String? defaultModelId;
  String? defaultProviderId;

  /// Environment variables every `opencode serve` is started with, and that
  /// mini-swe-agent's commands run under — API keys and whatever else a
  /// provider or a CLI reads out of one. Held here rather than in the process
  /// code because the settings page edits them.
  Map<String, String> opencodeEnv;

  /// Which runtime a new chat gets. Null means the platform's own default,
  /// which is the only thing that can pick before anything is configured.
  BackendKind? defaultBackend;

  /// Whether mini-swe-agent asks before running a command. A chat can override
  /// it; opencode has its own permission rules and ignores it.
  bool approveCommands;

  /// The endpoints mini-swe-agent can call. Empty until the user adds one,
  /// which is why the first thing settings offers is a list of presets.
  List<LlmProviderConfig> llmProviders;

  static AppSettings load(AppConfig config) {
    final file = config.settingsFile;
    if (!file.existsSync()) return AppSettings();
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return AppSettings(
        defaultModelId: _orNull(json["defaultModelId"] as String?),
        defaultProviderId: _orNull(json["defaultProviderId"] as String?),
        opencodeEnv: _stringMap(json["opencodeEnv"]),
        defaultBackend: _backend(json["defaultBackend"]),
        approveCommands: json["approveCommands"] as bool? ?? true,
        llmProviders: _providers(json["llmProviders"]),
      );
    } catch (_) {
      return AppSettings();
    }
  }

  // Builds before the /provider flattening fix wrote empty ids here.
  static String? _orNull(String? v) => (v == null || v.isEmpty) ? null : v;

  static BackendKind? _backend(Object? value) =>
      BackendKind.values.where((kind) => kind.name == value).firstOrNull;

  static List<LlmProviderConfig> _providers(Object? value) {
    if (value is! List) return const [];
    return [
      for (final entry in value) ?LlmProviderConfig.fromJson(entry),
    ];
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.value is String) entry.key.toString(): entry.value as String,
    };
  }

  /// A fresh instance holding the same values, for a notifier that has to hand
  /// out a new object to be noticed. The fields are mutable, so a caller
  /// changes what it means to with a cascade — which keeps `null` meaning
  /// "not set" rather than "leave alone", and needs no sentinel to say so.
  AppSettings copy() => AppSettings(
        defaultModelId: defaultModelId,
        defaultProviderId: defaultProviderId,
        opencodeEnv: opencodeEnv,
        defaultBackend: defaultBackend,
        approveCommands: approveCommands,
        llmProviders: llmProviders,
      );

  Future<void> save(AppConfig config) async {
    config.settingsFile.writeAsStringSync(jsonEncode({
      if (defaultModelId != null) "defaultModelId": defaultModelId,
      if (defaultProviderId != null) "defaultProviderId": defaultProviderId,
      if (opencodeEnv.isNotEmpty) "opencodeEnv": opencodeEnv,
      if (defaultBackend != null) "defaultBackend": defaultBackend!.name,
      if (!approveCommands) "approveCommands": approveCommands,
      if (llmProviders.isNotEmpty)
        "llmProviders": [for (final provider in llmProviders) provider.toJson()],
    }));
  }
}
