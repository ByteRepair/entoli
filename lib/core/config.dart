import "dart:io";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../domain/models.dart";
import "../domain/project.dart";

/// Resolves platform-specific paths for the agent-chat data directory and
/// provides helpers for constructing chat paths.
///
/// Layout:
///   `<dataDir>/settings.json`
///   `<dataDir>/commands/*.md`, `<dataDir>/agents/*.md`
///   `<dataDir>/chats/<chat-id>/`
///     state.json
///     conv.json
///     meta.json
///     resources/
///     workspace/
///   `<dataDir>/workspace/`
///   `<dataDir>/projects/<project>/{chats,workspace}/`
///
/// Every path but the first three is a project's: `null` is the default
/// project, and it is the data directory itself, so a chat written before
/// there were projects is already in it.
class AppConfig {
  AppConfig._(this.dataDir);

  /// Test-only constructor using an explicit data directory.
  @visibleForTesting
  AppConfig.forDirectory(this.dataDir);

  final Directory dataDir;

  static Future<AppConfig> load() async {
    final override = Platform.environment["AGENT_CHAT_CONFIG"];
    final config = AppConfig._(
      Directory(override ?? p.join(await _resolveBase(), "agent-chat")),
    );
    config.ensureDirs();
    return config;
  }

  static Future<String> _resolveBase() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    }
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      return p.join(_home, ".config");
    }
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  static String get _home =>
      Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"]!;

  Directory get projectsDir => Directory(p.join(dataDir.path, "projects"));

  /// Every project-scoped path goes through here, so this is where a name that
  /// would reach outside `projects/` is refused rather than joined.
  Directory projectDir({String? project}) {
    if (project == null) return dataDir;
    if (!isProjectName(project)) {
      throw ArgumentError.value(project, "project", "not a project name");
    }
    return Directory(p.join(projectsDir.path, project));
  }

  Directory chatsDir({String? project}) =>
      Directory(p.join(projectDir(project: project).path, "chats"));

  /// The workspace every chat in the project shares, beside the one each has
  /// of its own.
  Directory projectWorkspaceDir({String? project}) =>
      Directory(p.join(projectDir(project: project).path, "workspace"));

  Directory chatDir(String chatId, {String? project}) =>
      Directory(p.join(chatsDir(project: project).path, chatId));

  File stateFile(String chatId, {String? project}) =>
      File(p.join(chatDir(chatId, project: project).path, "state.json"));

  File convFile(String chatId, {String? project}) =>
      File(p.join(chatDir(chatId, project: project).path, "conv.json"));

  File metaFile(String chatId, {String? project}) =>
      File(p.join(chatDir(chatId, project: project).path, "meta.json"));

  Directory resourcesDir(String chatId, {String? project}) =>
      Directory(p.join(chatDir(chatId, project: project).path, "resources"));

  Directory workspaceDir(String chatId, {String? project}) =>
      Directory(p.join(chatDir(chatId, project: project).path, "workspace"));

  /// Where the user's own commands and agents go, beside the presets the app
  /// ships with. App-wide: a project scopes files, not what the composer offers.
  Directory promptsDir(CompletionKind kind) => Directory(p.join(dataDir.path, kind.folder));

  /// Create a chat's directories. Reading a path no longer creates it, so the
  /// few places that need them on disk say so.
  void ensureChatDirs(String chatId, {String? project}) {
    _ensure([
      chatDir(chatId, project: project),
      resourcesDir(chatId, project: project),
      workspaceDir(chatId, project: project),
    ]);
  }

  /// A project is its directories: there is nothing else to create one, and
  /// the shared workspace is named in the agent's prompt whether or not
  /// anything has been put in it yet.
  void ensureProjectDirs({String? project}) {
    _ensure([chatsDir(project: project), projectWorkspaceDir(project: project)]);
  }

  /// The prompt directories are created empty rather than on demand: an
  /// absent one is a worse hint than an empty one about where a custom
  /// command goes.
  void ensureDirs() {
    _ensure([
      dataDir,
      projectsDir,
      for (final kind in CompletionKind.values) promptsDir(kind),
    ]);
    ensureProjectDirs();
  }

  void _ensure(List<Directory> dirs) {
    for (final dir in dirs) {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }
  }

  File get settingsFile => File(p.join(dataDir.path, "settings.json"));
}
