import "package:flutter/foundation.dart";
import "package:fs_shim/fs.dart";

import "../domain/documents.dart";
import "../domain/models.dart";
import "../domain/project.dart";

/// Composes the paths of the Entoli data directory, and holds the filesystem
/// they lead into. This file builds names; [fs] is what they mean.
///
/// Layout:
///   `<dataDir>/settings.json`
///   `<dataDir>/commands/*.md`, `<dataDir>/agents/*.md`
///   `<dataDir>/chats/<chat-id>/`
///     state.json
///     conv.jsonl
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
  AppConfig._(this.dataDir, this.fs) : documents = Documents(fs);

  /// Test-only constructor using an explicit data directory. Creates nothing,
  /// and hydrates nothing.
  @visibleForTesting
  AppConfig.forDirectory(this.dataDir, this.fs) : documents = Documents(fs);

  final String dataDir;

  /// A real filesystem on desktop and Android, IndexedDB in a browser. The
  /// layout is the same either way, which is the point of it being a port.
  final FileSystem fs;

  /// The handful of documents that have to be readable synchronously.
  final Documents documents;

  static Future<AppConfig> load(FileSystem fs, String dataDir) async {
    final config = AppConfig._(dataDir, fs);
    await config.ensureDirs();
    await config.documents.hydrate([
      config.settingsFile,
      for (final project in everyProject(await config.projectNames()))
        config.projectSettingsFile(project: project),
    ]);
    return config;
  }

  String get projectsDir => fs.path.join(dataDir, "projects");

  /// Every project-scoped path goes through here, so this is where a name that
  /// would reach outside `projects/` is refused rather than joined.
  String projectDir({String? project}) {
    if (project == null) return dataDir;
    if (!isProjectName(project)) {
      throw ArgumentError.value(project, "project", "not a project name");
    }
    return fs.path.join(projectsDir, project);
  }

  /// The projects that exist, by name, sorted. A directory that could not have
  /// been created as a project is not one, so a stray `.git` beside them is not
  /// listed.
  Future<List<String>> projectNames() async {
    final dir = fs.directory(projectsDir);
    if (!await dir.exists()) return const [];
    final names = <String>[
      await for (final entity in dir.list())
        if (entity is Directory) fs.path.basename(entity.path),
    ];
    return names.where(isProjectName).toList()..sort();
  }

  String chatsDir({String? project}) =>
      fs.path.join(projectDir(project: project), "chats");

  /// The workspace every chat in the project shares, beside the one each has
  /// of its own.
  String projectWorkspaceDir({String? project}) =>
      fs.path.join(projectDir(project: project), "workspace");

  String chatDir(String chatId, {String? project}) =>
      fs.path.join(chatsDir(project: project), chatId);

  String stateFile(String chatId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "state.json");

  /// The conversation, as the log of `ChatRecord`s it is appended to. Not a
  /// document: see `chat_log.dart` for why.
  String convFile(String chatId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "conv.jsonl");

  String metaFile(String chatId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "meta.json");

  String resourcesDir(String chatId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "resources");

  /// Where artifacts live: one subdir per `artifactId`, each holding an
  /// `index.html` and whatever supporting files the model sent. A sibling of
  /// `resources/` and `workspace/` rather than under either, the way
  /// `subagents/` is — each dir has one purpose and one access pattern.
  String artifactsDir(String chatId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "artifacts");

  String artifactDir(String chatId, String artifactId, {String? project}) =>
      fs.path.join(artifactsDir(chatId, project: project), artifactId);

  String workspaceDir(String chatId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "workspace");

  /// A `task` call's own transcript, in the same format as [convFile] and named
  /// by the call that spawned it. That id is the only one there is, and the
  /// parent's log already holds it, so nothing has to be written down to pair
  /// the two.
  String subAgentsDir(String chatId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "subagents");

  String subAgentFile(String chatId, String callId, {String? project}) =>
      fs.path.join(subAgentsDir(chatId, project: project), "$callId.jsonl");

  /// Where the user's own commands and agents go, beside the presets the app
  /// ships with. App-wide: a project scopes files, not what the composer offers.
  String promptsDir(CompletionKind kind) => fs.path.join(dataDir, kind.folder);

  /// Create a chat's directories. Reading a path no longer creates it, so the
  /// few places that need them on the filesystem say so.
  Future<void> ensureChatDirs(String chatId, {String? project}) => _ensure([
        chatDir(chatId, project: project),
        resourcesDir(chatId, project: project),
        artifactsDir(chatId, project: project),
        workspaceDir(chatId, project: project),
      ]);

  /// A project is its directories: there is nothing else to create one, and
  /// the shared workspace is named in the agent's prompt whether or not
  /// anything has been put in it yet.
  Future<void> ensureProjectDirs({String? project}) => _ensure([
        chatsDir(project: project),
        projectWorkspaceDir(project: project),
      ]);

  /// The prompt directories are created empty rather than on demand: an
  /// absent one is a worse hint than an empty one about where a custom
  /// command goes.
  Future<void> ensureDirs() async {
    await _ensure([
      dataDir,
      projectsDir,
      for (final kind in CompletionKind.values) promptsDir(kind),
    ]);
    await ensureProjectDirs();
  }

  Future<void> _ensure(List<String> dirs) async {
    for (final dir in dirs) {
      await fs.directory(dir).create(recursive: true);
    }
  }

  String get settingsFile => fs.path.join(dataDir, "settings.json");

  /// Project-scoped overrides. The default project is null, and it is the data
  /// directory, so its settings sit beside `settings.json` rather than under
  /// `projects/`.
  String projectSettingsFile({String? project}) =>
      fs.path.join(projectDir(project: project), "project.json");
}
