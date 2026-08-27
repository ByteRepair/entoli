import "dart:convert";

import "../core/config.dart";
import "temp_chat_ttl.dart";

/// Project-scoped overrides. A project can override the app-level
/// [TempChatTtl] with one of its own, keep an auto-memory store of its own,
/// and set command environment variables of its own beside the app-level
/// ones. Null means "inherit the app default". What a project says to its
/// turns is not here: that is the AGENTS.md at its workspace root, read with
/// the instructions.
class ProjectSettings {
  ProjectSettings(
      {this.tempChatTtl, this.environment, this.useProjectMemory = false});

  /// How long a temporary chat in this project lives. Null means inherit the
  /// app default.
  TempChatTtl? tempChatTtl;

  /// What the project's commands run under, beside the app-level variables:
  /// a name set here wins over one set there. Null means none.
  Map<String, String>? environment;

  /// Whether this project keeps an auto-memory store of its own instead of
  /// sharing the default project's. Meaningless for the default project
  /// itself, which is the one every other falls back to.
  bool useProjectMemory;

  static ProjectSettings load(AppConfig config, {String? project}) {
    final text = config.documents.read(config.projectSettingsFile(project: project));
    if (text == null) return ProjectSettings();
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      // A decode gives a `Map<String, dynamic>`, so the value test is what
      // keeps a number in there out of a command's environment.
      final env = json["environment"];
      final environment = env is Map<String, dynamic> && env.values.every((v) => v is String)
          ? {for (final e in env.entries) e.key: e.value as String}
          : null;
      return ProjectSettings(
        tempChatTtl: TempChatTtl.fromNameNullable(json["tempChatTtl"] as String?),
        environment: environment,
        useProjectMemory: json["useProjectMemory"] as bool? ?? false,
      );
    } catch (_) {
      return ProjectSettings();
    }
  }

  Future<void> save(AppConfig config, {String? project}) async {
    await config.documents.write(config.projectSettingsFile(project: project), jsonEncode({
      if (tempChatTtl != null) "tempChatTtl": tempChatTtl!.name,
      if (environment != null && environment!.isNotEmpty) "environment": environment,
      if (useProjectMemory) "useProjectMemory": useProjectMemory,
    }));
  }

  ProjectSettings copy() => ProjectSettings(
        tempChatTtl: tempChatTtl,
        environment: environment,
        useProjectMemory: useProjectMemory,
      );
}
