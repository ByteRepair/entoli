import "dart:convert";

import "../core/config.dart";

/// Persisted app-level settings (default model for new chats, etc.).
class AppSettings {
  AppSettings({
    this.defaultModelId,
    this.defaultProviderId,
    this.opencodeEnv = const {},
  });

  String? defaultModelId;
  String? defaultProviderId;

  /// Environment variables every `opencode serve` is started with — API keys
  /// and whatever else a provider reads out of the environment. Held here
  /// rather than in the process code because the settings page edits them.
  Map<String, String> opencodeEnv;

  static AppSettings load(AppConfig config) {
    final file = config.settingsFile;
    if (!file.existsSync()) return AppSettings();
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return AppSettings(
        defaultModelId: _orNull(json["defaultModelId"] as String?),
        defaultProviderId: _orNull(json["defaultProviderId"] as String?),
        opencodeEnv: _stringMap(json["opencodeEnv"]),
      );
    } catch (_) {
      return AppSettings();
    }
  }

  // Builds before the /provider flattening fix wrote empty ids here.
  static String? _orNull(String? v) => (v == null || v.isEmpty) ? null : v;

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.value is String) entry.key.toString(): entry.value as String,
    };
  }

  Future<void> save(AppConfig config) async {
    config.settingsFile.writeAsStringSync(jsonEncode({
      if (defaultModelId != null) "defaultModelId": defaultModelId,
      if (defaultProviderId != null) "defaultProviderId": defaultProviderId,
      if (opencodeEnv.isNotEmpty) "opencodeEnv": opencodeEnv,
    }));
  }
}
