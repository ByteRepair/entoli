import "package:flutter/foundation.dart";
import "package:fs_shim/fs.dart";

import "../domain/documents.dart";
import "../domain/models.dart";
import "../domain/project.dart";
import "migrations.dart";

/// The name the instruction files go by, at the data dir's root and at each
/// project's workspace root.
const instructionFileName = "AGENTS.md";

/// The first sentence `renderInstructions` writes over the files it loaded —
/// and the marker the read label's drawer cuts the tool output at, so the
/// rendered block a nested read appends to a result is not shown as though it
/// were the file's content. One const for both ends, so they cannot disagree.
const instructionBlockHeader = "Workspace instructions are shown below";

/// Composes the paths of the Entoli data directory, and holds the filesystem
/// they lead into. This file builds names; [fs] is what they mean.
///
/// Layout:
///   `<dataDir>/settings.json`
///   `<dataDir>/reminders.json`
///   `<dataDir>/projects/<project>/`
///     `project.json`
///     `chats/<chat-id>/` — state.json, conv.jsonl, meta.json, resources/,
///        artifacts/, subagents/
///     `workspace/`, holding `chats/<chat-id>/`
///     `agents/*.md`, `skills/<name>/`, `skills-bundled/<name>/`
///
/// Every path but the first two is a project's, and every project is a
/// directory under `projects/` — the default one included, under the name
/// `defaultProjectDir`. The default project holds the base skills and agents
/// every other project inherits; another project's own `agents/` and `skills/`
/// override a same-named default entry for that project alone. Moving any of
/// it in a release is what `migrations.dart` is for.
///
/// A chat's own workspace is *inside* the project's rather than beside its
/// conversation: it is where the chat's commands start, and the project
/// workspace above it is their `HOME`, so one project is one environment. What
/// a chat is — the log and what was attached to it — stays in `chats/`, which
/// the agent never has a path to.
///
/// The workspace half of this layout is spoken a second time, in Kotlin, by
/// `WorkspaceProvider` — it answers Android's Files app with no engine running,
/// so moving `workspace/` or `chats/` has to move there too.
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
    await runMigrations(config, fresh: await config.ensureDirs());
    await config.documents.hydrate([
      config.settingsFile,
      for (final project in everyProject(await config.projectNames()))
        config.projectSettingsFile(project: project),
    ]);
    return config;
  }

  String get projectsDir => fs.path.join(dataDir, "projects");

  /// This device's sync identity, its paired devices, and their secrets where
  /// there is no keyring to hold them. A backup skips it whole — see
  /// `writeBackup` — so a restore leaves it to [ensureDirs] to make again.
  String get syncDir => fs.path.join(dataDir, "sync");

  /// Every project-scoped path goes through here, so this is where a name that
  /// would reach outside `projects/` is refused rather than joined. A built-in
  /// project's name has the directory shape, so it passes: a chat can be in
  /// one. What refuses it is [isProjectName], where a user names a project.
  String projectDir({String? project}) {
    if (project == null) return fs.path.join(projectsDir, defaultProjectDir);
    if (!isProjectDirName(project)) {
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

  /// Where a project's auto-memory lives: beside `chats/` and `workspace/`,
  /// app-managed rather than user scratch space. The default project's store
  /// answers for every project that has not turned its own on.
  String memoryDir({String? project}) =>
      fs.path.join(projectDir(project: project), "memory");

  /// The workspace every chat in the project shares, beside the one each has
  /// of its own.
  String projectWorkspaceDir({String? project}) =>
      fs.path.join(projectDir(project: project), "workspace");

  /// A project's own rootfs copy, for a built-in that opts into rootfs
  /// isolation. The base download in cache is the template; this is its
  /// living filesystem.
  String projectRootfsDir({String? project, required String rootfsId}) =>
      fs.path.join(projectDir(project: project), "rootfs", rootfsId);

  /// The marker file that says a project requiring setup has been set up.
  /// Written by the store that runs setup, read by `setupCompleteProvider`.
  String setupCompleteFile({String? project}) =>
      fs.path.join(projectDir(project: project), ".setup-complete");

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

  /// Where a `create_skill` tool's packaged `.skill` is staged for the user to
  /// install. A sibling of `artifacts/` — one dir per install, deleted with the
  /// chat.
  String skillStagingDir(String chatId, String installId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "skill-installs", installId);

  /// Where a chat's commands run, under the workspace they share rather than
  /// beside the conversation: see the layout above.
  String workspaceDir(String chatId, {String? project}) =>
      fs.path.join(projectWorkspaceDir(project: project), "chats", chatId);

  /// A `task` call's own transcript, in the same format as [convFile] and named
  /// by the call that spawned it. That id is the only one there is, and the
  /// parent's log already holds it, so nothing has to be written down to pair
  /// the two.
  String subAgentsDir(String chatId, {String? project}) =>
      fs.path.join(chatDir(chatId, project: project), "subagents");

  String subAgentFile(String chatId, String callId, {String? project}) =>
      fs.path.join(subAgentsDir(chatId, project: project), "$callId.jsonl");

  /// The default project's own skills and agents, beside its `chats/` and
  /// `workspace/`. Every project derives from the default one: a project's
  /// own entry replaces a same-named default entry for that project alone,
  /// and what it does not override falls through. See "Skills and agents"
  /// in `lib/domain/AGENTS.md`. `null` is the default project, the way it is
  /// for every project-scoped path.
  String promptsDir(CompletionKind kind, {String? project}) =>
      fs.path.join(projectDir(project: project), kind.folder);

  /// Where the bundled skills are extracted to at startup, so a skill's
  /// scripts and reference files have a real base directory. Beside the
  /// user's [promptsDir] rather than in it: `skills/` is purely theirs, so
  /// deleting a skill there deletes it. Per-project, the way [promptsDir] is.
  String bundledSkillsDir({String? project}) =>
      fs.path.join(projectDir(project: project), "skills-bundled");

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
  /// anything has been put in it yet. Its own skills and agents dirs are made
  /// here too, so a project's overrides have somewhere to live the moment it
  /// exists — the way the default one's do at startup.
  Future<void> ensureProjectDirs({String? project}) => _ensure([
        chatsDir(project: project),
        projectWorkspaceDir(project: project),
        for (final kind in CompletionKind.values)
          promptsDir(kind, project: project),
      ]);

  /// True where this call created the data directory, which is what says a
  /// migration has nothing here to move — asked by the call that creates them,
  /// since afterwards there is nobody left to ask.
  ///
  /// The default project's prompt directories are created empty rather than on
  /// demand: an absent one is a worse hint than an empty one about where a
  /// custom command goes. Every other project's are made with it, through
  /// [ensureProjectDirs].
  Future<bool> ensureDirs() async {
    final fresh = !await fs.directory(dataDir).exists();
    await _ensure([
      dataDir,
      projectsDir,
      syncDir,
    ]);
    await ensureProjectDirs();
    return fresh;
  }

  Future<void> _ensure(List<String> dirs) async {
    for (final dir in dirs) {
      await fs.directory(dir).create(recursive: true);
    }
  }

  /// The user's global instructions, at the data dir's root: the one file the
  /// instruction load reads that is not inside a project. Outside the
  /// workspaces, so a turn's file tools cannot reach it.
  String get globalInstructionsFile =>
      fs.path.join(dataDir, instructionFileName);

  /// The project's instructions, at its workspace root, shared by its chats.
  String projectInstructionsFile({String? project}) =>
      fs.path.join(projectWorkspaceDir(project: project), instructionFileName);

  /// Not the app's version: it names the release whose migration last ran here,
  /// and a release that leaves the layout alone leaves this where it was. See
  /// `migrations.dart`.
  String get versionFile => fs.path.join(dataDir, "version");

  String get settingsFile => fs.path.join(dataDir, "settings.json");

  /// The user's triggers, one JSON list. Not a document in [Documents]:
  /// nothing needs to read it synchronously, and Kotlin reads it behind the
  /// app's back to re-arm alarms — which is why writes go through a rename.
  ///
  /// Named for what was stored here rather than for what is: the file the
  /// reminder feature wrote is the one the trigger feature reads, and
  /// renaming it would be a migration, which renaming a feature is not.
  String get remindersFile => fs.path.join(dataDir, "reminders.json");

  /// Project-scoped overrides, in the project's own directory — the default
  /// project's included, which is what makes them one kind of file in one
  /// place.
  String projectSettingsFile({String? project}) =>
      fs.path.join(projectDir(project: project), "project.json");
}
