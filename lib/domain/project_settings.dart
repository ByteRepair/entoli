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
    final file = config.projectSettingsFile(project: project);
    if (!file.existsSync()) return ProjectSettings();
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return ProjectSettings(profile: Profile.fromJson(json["profile"]));
    } catch (_) {
      return ProjectSettings();
    }
  }

  Future<void> save(AppConfig config, {String? project}) async {
    final file = config.projectSettingsFile(project: project);
    file.writeAsStringSync(jsonEncode({
      if (profile != null && !profile!.isEmpty) "profile": profile!.toJson(),
    }));
  }

  ProjectSettings copy() => ProjectSettings(profile: profile);
}