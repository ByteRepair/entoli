import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart" show ZipEncoder;
import "package:file/file.dart";
import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../model/config.dart";
import "../model/read_only_dirs.dart";
import "../model/log.dart";
import "zip.dart" show archiveOf;
import "../model/chat_log.dart";
import "../model/chat_meta.dart";
import "../model/documents.dart";
import "../model/chat_store.dart";
import "../model/models.dart";
import "../model/plan.dart" show planFileName;
import "../model/artifact_style.dart";
import "../model/project.dart";

/// The `ChatStore`, over the data directory's filesystem.
class FileChatStore implements ChatStore {
  FileChatStore(this.config, {this.deleteTree, ReadOnlyDirs? readOnlyDirs})
    : _write = RenameWriter(config.fs),
      _readOnly = readOnlyDirs ?? ReadOnlyDirs.none();

  final AppConfig config;

  FileSystem get _fs => config.fs;

  /// The platform's tree delete, which gets past the read-only directories
  /// (`ReadOnlyDirs`) and proot's mode-0000 stubs a plain recursive delete
  /// dies on. Null in a test that makes neither.
  final Future<void> Function(String path)? deleteTree;

  /// A chat's `resources/` is one of these: the agent reads its attachments
  /// and never writes them.
  final ReadOnlyDirs _readOnly;

  /// Which project each chat is in. A chat is addressed by its id alone, so
  /// this is how its directory is found: [list] fills it, and an id it has
  /// never seen is looked for on the filesystem.
  final Map<String, String?> _projects = {};

  /// For the documents beside the log, so a read never lands between a
  /// truncate and a write. The log itself is appended to.
  final RenameWriter _write;

  Future<String?> _readOrNull(String path) async {
    final file = _fs.file(path);
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<List<ChatState>> list() async {
    final chats = <ChatState>[];
    for (final project in everyProject(await config.projectNames())) {
      chats.addAll(await _listIn(project));
    }
    chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return chats;
  }

  /// Where a chat was found wins over what its `state.json` says, so one moved
  /// by hand is in the project it was moved to.
  Future<List<ChatState>> _listIn(String? project) async {
    final dir = _fs.directory(config.chatsDir(project: project));
    if (!dir.existsSync()) return const [];
    final chats = <ChatState>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final state = await _readState(p.basename(entity.path), project);
      if (state != null) chats.add(state);
    }
    return chats;
  }

  Future<ChatState?> _readState(String id, String? project) async {
    final text = await _readOrNull(config.stateFile(id, project: project));
    if (text == null) return null;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      _projects[id] = project;
      return ChatState.fromJson(json).copyWith(project: project);
    } catch (e) {
      logFailure("store", "state.json of $id could not be read", e);
      return null;
    }
  }

  @override
  Future<List<String>> listProjects() => config.projectNames();

  /// Where a chat's files already are, or null if it has none yet. Wrapped
  /// because being in the default project is `null` as well, and the two mean
  /// opposite things to a save.
  Future<({String? project})?> _locate(String chatId) async {
    if (_projects.containsKey(chatId)) return (project: _projects[chatId]);
    for (final project in everyProject(await config.projectNames())) {
      if (_fs.file(config.stateFile(chatId, project: project)).existsSync()) {
        _projects[chatId] = project;
        return (project: project);
      }
    }
    return null;
  }

  /// A chat nothing has been written for is answered as the default project,
  /// which is where a new one goes unless it says otherwise.
  @override
  Future<String?> projectOf(String chatId) async =>
      (await _locate(chatId))?.project;

  @override
  Future<void> createProject(String name) =>
      config.ensureProjectDirs(project: name);

  @override
  Future<void> deleteProject(String name) async {
    final path = config.projectDir(project: name);
    final dir = _fs.directory(path);
    if (dir.existsSync()) {
      final delete = deleteTree;
      delete != null ? await delete(path) : await dir.delete(recursive: true);
    }
    _projects.removeWhere((_, project) => project == name);
  }

  @override
  Future<void> moveChat(String chatId, String? project) async {
    final was = await projectOf(chatId);
    final to = config.chatDir(chatId, project: project);
    final from = config.chatDir(chatId, project: was);
    if (!_fs.directory(from).existsSync() || from == to) return;
    await config.ensureProjectDirs(project: project);
    await _fs.directory(from).rename(to);
    // The workspace is in the project's, not in the chat directory that just
    // moved, so it is a second move.
    final workspace = _fs.directory(config.workspaceDir(chatId, project: was));
    if (workspace.existsSync()) {
      final target = config.workspaceDir(chatId, project: project);
      await _fs.directory(p.dirname(target)).create(recursive: true);
      await workspace.rename(target);
    }
    _projects[chatId] = project;
    // `state.json` names its project too, so a chat read straight off the
    // filesystem still knows where it is.
    final state = await _readState(chatId, project);
    if (state != null) await saveState(state);
  }

  @override
  Future<String> importChat(
    String dataDir,
    String chatId, {
    String? project,
  }) async {
    final from = AppConfig.forDirectory(_fs, dataDir);
    final state = ChatState.fromJson(
      jsonDecode(await _fs.file(from.stateFile(chatId)).readAsString())
          as Map<String, dynamic>,
    );
    final id = const Uuid().v4();
    await config.ensureProjectDirs(project: project);
    await _place(from.chatDir(chatId), config.chatDir(id, project: project));
    final workspace = from.workspaceDir(chatId);
    if (_fs.directory(workspace).existsSync()) {
      await _place(workspace, config.workspaceDir(id, project: project));
    }
    _projects[id] = project;
    await saveState(
      state.copyWith(
        id: id,
        project: project,
        imported: true,
        updatedAt: DateTime.now(),
      ),
    );
    await lockResources(id);
    return id;
  }

  /// [from] moved to [to], or copied where a rename cannot reach — another
  /// filesystem, as the system's temp directory often is.
  Future<void> _place(String from, String to) async {
    await _fs.directory(p.dirname(to)).create(recursive: true);
    try {
      await _fs.directory(from).rename(to);
    } on FileSystemException {
      await _fs.directory(to).create(recursive: true);
      await _copyDir(_fs.directory(from), to);
    }
  }

  @override
  Future<Chat> load(String id) async {
    final state = await _readState(id, await projectOf(id));
    if (state == null) throw StateError("no chat $id");
    return chatFrom(state, await readRecords(id));
  }

  @override
  Future<ChatState?> loadState(String id) async =>
      _readState(id, await projectOf(id));

  @override
  Future<List<ChatRecord>> readRecords(String chatId) async {
    final text = await _readOrNull(
      config.convFile(chatId, project: await projectOf(chatId)),
    );
    return text == null ? const [] : decodeLog(text);
  }

  @override
  Future<List<ChatRecord>> readSubAgentRecords(
    String chatId,
    String callId,
  ) async {
    final text = await _readOrNull(
      config.subAgentFile(chatId, callId, project: await projectOf(chatId)),
    );
    return text == null ? const [] : decodeLog(text);
  }

  @override
  Future<void> append(String chatId, List<ChatRecord> records) async {
    if (records.isEmpty) return;
    // No `ensureChatDirs`: every append follows the `saveState` that created
    // the chat's directory, and three directory checks per checkpoint are
    // three stats on the path a turn waits for.
    final project = await projectOf(chatId);
    // Straight onto the end of the file, not through [_write]: a rename would
    // have to write out everything already there to put one line on it.
    await _fs
        .file(config.convFile(chatId, project: project))
        .writeAsString(encodeLog(records), mode: FileMode.append);
  }

  @override
  Future<void> saveState(ChatState state) async {
    // Where the chat already is wins: a copy held from before it was moved
    // would otherwise write a second one back where it used to be. Its own
    // project only says where a chat that is nowhere yet should go.
    final located = await _locate(state.id);
    final project = located == null ? state.project : located.project;
    _projects[state.id] = project;
    await config.ensureChatDirs(state.id, project: project);
    await _write.write(
      config.stateFile(state.id, project: project),
      jsonEncode(state.copyWith(project: project).toJson()),
    );
  }

  @override
  Future<void> retitle(String chatId, String title) async {
    final project = await projectOf(chatId);
    final state = await _readState(chatId, project);
    if (state == null) return;
    await saveState(state.copyWith(title: title));
  }

  @override
  Future<void> delete(String id) async {
    final project = await projectOf(id);
    for (final path in [
      config.chatDir(id, project: project),
      config.workspaceDir(id, project: project),
    ]) {
      final dir = _fs.directory(path);
      if (!dir.existsSync()) continue;
      // The tree delete gets past the locked `resources/` inside.
      final delete = deleteTree;
      delete != null ? await delete(path) : await dir.delete(recursive: true);
    }
    _projects.remove(id);
  }

  @override
  Future<String> saveResource(
    String chatId,
    String filename,
    Uint8List bytes,
  ) async {
    final project = await projectOf(chatId);
    await config.ensureChatDirs(chatId, project: project);
    final resource = resourceName(filename);
    final dir = config.resourcesDir(chatId, project: project);
    await _readOnly
        .of(dir)
        .write(() => _fs.file(p.join(dir, resource)).writeAsBytes(bytes));
    return resource;
  }

  @override
  Future<void> lockResources(String chatId) async {
    final dir = config.resourcesDir(chatId, project: await projectOf(chatId));
    if (_fs.directory(dir).existsSync()) await _readOnly.of(dir).lock();
  }

  @override
  Future<Uint8List?> readResource(String chatId, String resource) async {
    final file = await _resourceFile(chatId, resource);
    return file.existsSync() ? file.readAsBytes() : null;
  }

  @override
  Future<void> deleteResource(String chatId, String resource) async {
    final file = await _resourceFile(chatId, resource);
    if (!file.existsSync()) return;
    await _readOnly.of(p.dirname(file.path)).write(file.delete);
  }

  Future<File> _resourceFile(String chatId, String resource) async {
    final dir = config.resourcesDir(chatId, project: await projectOf(chatId));
    return _fs.file(p.join(dir, p.basename(resource)));
  }

  @override
  Future<ChatMeta> loadMeta(String chatId) async => ChatMeta.parse(
    await _readOrNull(
      config.metaFile(chatId, project: await projectOf(chatId)),
    ),
  );

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async {
    final project = await projectOf(chatId);
    await config.ensureChatDirs(chatId, project: project);
    await _write.write(
      config.metaFile(chatId, project: project),
      meta.encode(),
    );
  }

  @override
  Future<String> createArtifact(
    String chatId,
    String sourceDir,
    String entryFile, {
    String? project,
  }) async {
    project = project ?? await projectOf(chatId);
    await config.ensureChatDirs(chatId, project: project);
    final artifactId = const Uuid().v4();
    await _publish(
      config.artifactDir(chatId, artifactId, project: project),
      sourceDir,
      entryFile,
    );
    return artifactId;
  }

  @override
  Future<void> updateArtifact(
    String chatId,
    String artifactId,
    String sourceDir,
    String entryFile, {
    String? project,
  }) async {
    project = project ?? await projectOf(chatId);
    final target = config.artifactDir(chatId, artifactId, project: project);
    final dir = _fs.directory(target);
    if (dir.existsSync()) await dir.delete(recursive: true);
    await _publish(target, sourceDir, entryFile);
  }

  /// Copies [source] — a directory, or a file standing for its parent — into
  /// [target], then writes the base stylesheet into the entry file at publish
  /// time; see "Artifacts" in the root notes. A missing entry file is a line:
  /// nothing downstream would otherwise say why an artifact opened unstyled.
  Future<void> _publish(String target, String source, String entryFile) async {
    if (_fs.file(source).existsSync()) source = p.dirname(source);
    await _fs.directory(target).create(recursive: true);
    await _copyDir(_fs.directory(source), target, links: false);
    final file = _fs.file(p.join(target, entryFile));
    if (!file.existsSync()) {
      logFailure(
        "artifact",
        "Entry file missing from published artifact: "
            "$target/$entryFile",
      );
      return;
    }
    await file.writeAsString(injectBaseStyles(await file.readAsString()));
  }

  @override
  Future<Uint8List?> readArtifactZip(
    String chatId,
    String artifactId, {
    String? project,
  }) async {
    // On the far side of this call is a peer-named id (`_serveResource` strips
    // the prefix off the wire and hands the rest over), so the id is held to
    // what `createArtifact` hands out — one path segment, the way
    // `readResource` basenames what it reads back.
    final id = p.basename(artifactId);
    if (id != artifactId || id.isEmpty) return null;
    project = project ?? await projectOf(chatId);
    final dir = config.artifactDir(chatId, id, project: project);
    if (!_fs.isDirectorySync(dir)) return null;
    // `base` is the artifact root itself: the entries come out named relative
    // to it, the shape the unzip on the far side writes back.
    return ZipEncoder().encodeBytes(await archiveOf(_fs, [dir], base: dir));
  }

  @override
  Future<String?> readPlan(String chatId) async {
    final project = await projectOf(chatId);
    final file = _fs.file(
      p.join(config.workspaceDir(chatId, project: project), planFileName),
    );
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<String> artifactPath(
    String chatId,
    String artifactId, {
    String? project,
  }) async {
    project = project ?? await projectOf(chatId);
    return config.artifactDir(chatId, artifactId, project: project);
  }

  @override
  Future<Uint8List?> readSkillInstall(String chatId, String installId) async {
    final project = await projectOf(chatId);
    final dir = config.skillStagingDir(chatId, installId, project: project);
    final file = _fs.file(p.join(dir, "package.skill"));
    return file.existsSync() ? file.readAsBytes() : null;
  }
}

/// A link is never followed, which a link back up would make endless: it is
/// copied as the link, or with [links] false left out — for an artifact, where
/// what one leads to is the workspace's, which a share would then offer, and
/// the stylesheet written into an entry file that is one would land there.
Future<void> _copyDir(
  Directory source,
  String target, {
  bool links = true,
}) async {
  final fs = source.fileSystem;
  await for (final entity in source.list(followLinks: false)) {
    final dest = p.join(target, p.basename(entity.path));
    if (entity is Link) {
      if (links) await fs.link(dest).create(await entity.target());
    } else if (entity is File) {
      await fs.file(dest).writeAsBytes(await entity.readAsBytes());
    } else if (entity is Directory) {
      await fs.directory(dest).create(recursive: true);
      await _copyDir(entity, dest, links: links);
    }
  }
}
