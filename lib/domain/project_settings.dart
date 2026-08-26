import "dart:convert";

import "../core/config.dart";
import "profile.dart";
import "temp_chat_ttl.dart";

/// Project-scoped overrides. A project can override the app-level [Profile]
/// with one of its own, and the app-level [TempChatTtl] with one of its own.
/// Null means "inherit the app default".
class ProjectSettings {
  ProjectSettings({this.profile, this.tempChatTtl, this.useProjectMemory = false});

  Profile? profile;

  /// How long a temporary chat in this project lives. Null means inherit the
  /// app default.
  TempChatTtl? tempChatTtl;

  /// Whether this project keeps an auto-memory store of its own instead of
  /// sharing the default project's. Meaningless for the default project
  /// itself, which is the one every other falls back to.
  bool useProjectMemory;

  static ProjectSettings load(AppConfig config, {String? project}) {
    final text = config.documents.read(config.projectSettingsFile(project: project));
    if (text == null) return ProjectSettings();
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      return ProjectSettings(
        profile: Profile.fromJson(json["profile"]),
        tempChatTtl: TempChatTtl.fromNameNullable(json["tempChatTtl"] as String?),
        useProjectMemory: json["useProjectMemory"] as bool? ?? false,
      );
    } catch (_) {
      return ProjectSettings();
    }
  }

  Future<void> save(AppConfig config, {String? project}) async {
    await config.documents.write(config.projectSettingsFile(project: project), jsonEncode({
      if (profile != null && !profile!.isEmpty) "profile": profile!.toJson(),
      if (tempChatTtl != null) "tempChatTtl": tempChatTtl!.name,
      if (useProjectMemory) "useProjectMemory": useProjectMemory,
    }));
  }

  ProjectSettings copy() => ProjectSettings(
        profile: profile,
        tempChatTtl: tempChatTtl,
        useProjectMemory: useProjectMemory,
      );
}