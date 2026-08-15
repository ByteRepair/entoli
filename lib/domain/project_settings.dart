import "dart:convert";

import "../core/config.dart";
import "profile.dart";

/// Project-scoped overrides. A project can override the app-level [Profile]
/// with one of its own; nothing else is project-scoped yet, but the record is
/// here so the pattern is established. Null means "inherit the app default".
class ProjectSettings {
  ProjectSettings({this.profile});

  Profile? profile;

  static ProjectSettings load(AppConfig config, {String? project}) {
    final text = config.storage.read(config.projectSettingsFile(project: project).path);
    if (text == null) return ProjectSettings();
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      return ProjectSettings(profile: Profile.fromJson(json["profile"]));
    } catch (_) {
      return ProjectSettings();
    }
  }

  Future<void> save(AppConfig config, {String? project}) async {
    config.storage.write(config.projectSettingsFile(project: project).path, jsonEncode({
      if (profile != null && !profile!.isEmpty) "profile": profile!.toJson(),
    }));
  }

  ProjectSettings copy() => ProjectSettings(profile: profile);
}