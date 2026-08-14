import "dart:convert";

import "../core/config.dart";

/// Persisted app-level settings (default model for new chats, etc.).
class AppSettings {
  AppSettings({this.defaultModelId, this.defaultProviderId});

  String? defaultModelId;
  String? defaultProviderId;

  bool modelIsSet(String providerId, String modelId) =>
      defaultProviderId == providerId && defaultModelId == modelId;

  static AppSettings load(AppConfig config) {
    final file = config.settingsFile;
    if (!file.existsSync()) return AppSettings();
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return AppSettings(
        defaultModelId: _orNull(json["defaultModelId"] as String?),
        defaultProviderId: _orNull(json["defaultProviderId"] as String?),
      );
    } catch (_) {
      return AppSettings();
    }
  }

  // Builds before the /provider flattening fix wrote empty ids here.
  static String? _orNull(String? v) => (v == null || v.isEmpty) ? null : v;

  Future<void> save(AppConfig config) async {
    config.settingsFile.writeAsStringSync(jsonEncode({
      if (defaultModelId != null) "defaultModelId": defaultModelId,
      if (defaultProviderId != null) "defaultProviderId": defaultProviderId,
    }));
  }
}