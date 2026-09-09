import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart" show ZipEncoder;
import "package:fs_shim/fs.dart";
import "package:uuid/uuid.dart";

import "../../core/config.dart";
import "../../core/log.dart";
import "../../data/zip.dart" show archiveOf;
import "../../domain/chat_log.dart";
import "../../domain/chat_meta.dart";
import "../../domain/documents.dart";
import "../../domain/chat_store.dart";
import "../../domain/models.dart";
import "../../domain/artifact_style.dart";
import "../../domain/project.dart";
import "../../domain/workspace.dart";

/// The `ChatStore`, on whatever filesystem this platform was given: real
/// directories on desktop and Android, IndexedDB in a browser. One
/// implementation, because the layout is the same either way.
class FileChatStore implements ChatStore {
  FileChatStore(this.config) : _write = RenameWriter.fs(config.fs);

  final AppConfig config;

  FileSystem get _fs => config.fs;

  /// Which project each chat is in. A chat is addressed by its id alone, so
  /// this is how its directory is found: [list] fills it, and an id it has
  /// never seen is looked for on the filesystem.
  final Map<String, String?> _projects = {};

  /// Writing is two steps now that it is asynchronous — `writeAsString`
  /// truncates and only then writes — so a read landing between them finds an
  /// empty file where JSON should be. Renaming over the target is one step,
  /// and a reader sees either the whole old file or the whole new one. This is
  /// for the documents beside the log: the log itself is appended to, where
  /// the same hazard is a torn last line the reader drops.
  final RenameWriter _write;

  Future<void> _writeFile(String path, String text) => _write.write(path, text);

  Future<String?> _readOrNull(String path) async {
    final file = _fs.file(path);
    return await file.exists() ? file.readAsString() : null;
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
    if (!await dir.exists()) return const [];
    final chats = <ChatState>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final state = await _readState(_fs.path.basename(entity.path), project);
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
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> listProjects() => config.projectNames();

  @override
  Future<String?> projectOf(String chatId) => _projectOf(chatId);

  /// Where a chat's files already are, or null if it has none yet. Wrapped
  /// because being in the default project is `null` as well, and the two mean
  /// opposite things to a save.
  Future<({String? project})?> _locate(String chatId) async {
    if (_projects.containsKey(chatId)) return (project: _projects[chatId]);
    for (final project in everyProject(await config.projectNames())) {
      if (await _fs.file(config.stateFile(chatId, project: project)).exists()) {
        _projects[chatId] = project;
        return (project: project);
      }
    }
    return null;
  }

  /// A chat nothing has been written for is answered as the default project,
  /// which is where a new one goes unless it says otherwise.
  Future<String?> _projectOf(String chatId) async => (await _locate(chatId))?.project;

  @override
  Future<void> createProject(String name) => config.ensureProjectDirs(project: name);

  @override
  Future<void> deleteProject(String name) async {
    final dir = _fs.directory(config.projectDir(project: name));
    if (await dir.exists()) await dir.delete(recursive: true);
    _projects.removeWhere((_, project) => project == name);
  }

  @override
  Future<void> moveChat(String chatId, String? project) async {
    final was = await _projectOf(chatId);
    final to = config.chatDir(chatId, project: project);
    final from = config.chatDir(chatId, project: was);
    if (!await _fs.directory(from).exists() || from == to) return;
    await config.ensureProjectDirs(project: project);
    await _fs.directory(from).rename(to);
    // The workspace is in the project's, not in the chat directory that just
    // moved, so it is a second move.
    final workspace = _fs.directory(config.workspaceDir(chatId, project: was));
    if (await workspace.exists()) {
      final target = config.workspaceDir(chatId, project: project);
      await _fs.directory(_fs.path.dirname(target)).create(recursive: true);
      await workspace.rename(target);
    }
    _projects[chatId] = project;
    // `state.json` names its project too, so a chat read straight off the
    // filesystem still knows where it is.
    final state = await _readState(chatId, project);
    if (state != null) await saveState(state);
  }

  @override
  Future<Chat> load(String id) async {
    final project = await _projectOf(id);
    final state = await _readState(id, project);
    if (state == null) throw StateError("no chat $id");
    final text = await _readOrNull(config.convFile(id, project: project));
    return chatFrom(state, text == null ? const [] : decodeLog(text));
  }

  @override
  Future<ChatState?> loadState(String id) async =>
      _readState(id, await _projectOf(id));

  @override
  Future<List<ChatRecord>> readRecords(String chatId) async {
    final project = await _projectOf(chatId);
    final text =
        await _readOrNull(config.convFile(chatId, project: project));
    return text == null ? const [] : decodeLog(text);
  }

  @override
  Future<void> append(String chatId, List<ChatRecord> records) async {
    if (records.isEmpty) return;
    // No `ensureChatDirs`: every append follows the `saveState` that created
    // the chat's directory, and three directory checks per checkpoint is three
    // IndexedDB transactions on the path a turn waits for.
    final project = await _projectOf(chatId);
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
    await _writeFile(
      config.stateFile(state.id, project: project),
      jsonEncode(state.copyWith(project: project).toJson()),
    );
  }

  @override
  Future<void> retitle(String chatId, String title) async {
    final project = await _projectOf(chatId);
    final state = await _readState(chatId, project);
    if (state == null) return;
    await saveState(state.copyWith(title: title));
  }

  @override
  Future<void> delete(String id) async {
    final project = await _projectOf(id);
    for (final path in [
      config.chatDir(id, project: project),
      config.workspaceDir(id, project: project),
    ]) {
      final dir = _fs.directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    _projects.remove(id);
  }

  @override
  Future<String> saveResource(String chatId, String filename, Uint8List bytes) async {
    final project = await _projectOf(chatId);
    await config.ensureChatDirs(chatId, project: project);
    final resource = resourceName(filename);
    // Bytes, not text: a browser's filesystem stores them as bytes too, and
    // base64 would cost a third of the quota that is actually scarce there.
    await _fs
        .file(_fs.path.join(config.resourcesDir(chatId, project: project), resource))
        .writeAsBytes(bytes);
    return resource;
  }

  @override
  Future<Uint8List?> readResource(String chatId, String resource) async {
    final dir = config.resourcesDir(chatId, project: await _projectOf(chatId));
    final file = _fs.file(_fs.path.join(dir, _fs.path.basename(resource)));
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<ChatMeta> loadMeta(String chatId) async =>
      ChatMeta.parse(await _readOrNull(config.metaFile(chatId, project: await _projectOf(chatId))));

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async {
    final project = await _projectOf(chatId);
    await config.ensureChatDirs(chatId, project: project);
    await _writeFile(config.metaFile(chatId, project: project), meta.encode());
  }

  @override
  Future<String> createArtifact(
      String chatId, String sourceDir, String entryFile,
      {String? project}) async {
    project = project ?? await _projectOf(chatId);
    await config.ensureChatDirs(chatId, project: project);
    final artifactId = const Uuid().v4();
    final target = config.artifactDir(chatId, artifactId, project: project);
    await _copyDir(_fs, sourceDir, target);
    await _injectEntryStyles(target, entryFile);
    return artifactId;
  }

  @override
  Future<void> updateArtifact(String chatId, String artifactId,
      String sourceDir, String entryFile,
      {String? project}) async {
    project = project ?? await _projectOf(chatId);
    final target = config.artifactDir(chatId, artifactId, project: project);
    // Clear the old contents, then copy the new. `_copyDir` recreates the
    // target directory.
    final dir = _fs.directory(target);
    if (await dir.exists()) await dir.delete(recursive: true);
    await _copyDir(_fs, sourceDir, target);
    await _injectEntryStyles(target, entryFile);
  }

  /// The base stylesheet is written into the artifact's entry file at publish
  /// time rather than at open time; see "Artifacts" in the root notes. A
  /// missing entry file is a line, not silence: nothing downstream would
  /// otherwise say why an artifact opened unstyled.
  Future<void> _injectEntryStyles(String dir, String entryFile) async {
    final file = _fs.file(_fs.path.join(dir, entryFile));
    if (!await file.exists()) {
      logFailure("artifact", "Entry file missing from published artifact: "
          "$dir/$entryFile");
      return;
    }
    await file.writeAsString(injectBaseStyles(await file.readAsString()));
  }

  @override
  Future<Uint8List?> readArtifactFile(
    String chatId, String artifactId, String relativePath, {String? project}) async {
    project = project ?? await _projectOf(chatId);
    final dir = config.artifactDir(chatId, artifactId, project: project);
    final safe = safeRelativePath(_fs, relativePath);
    final file = _fs.file(_fs.path.join(dir, safe));
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<Uint8List?> readArtifactZip(String chatId, String artifactId,
      {String? project}) async {
    // On the far side of this call is a peer-named id (`_serveResource` strips
    // the prefix off the wire and hands the rest over), so the id is held to
    // what `createArtifact` hands out — one path segment, the way
    // `readResource` basenames what it reads back.
    final id = _fs.path.basename(artifactId);
    if (id != artifactId || id.isEmpty) return null;
    project = project ?? await _projectOf(chatId);
    final dir = config.artifactDir(chatId, id, project: project);
    if (!await _fs.isDirectory(dir)) return null;
    // `base` is the artifact root itself: the entries come out named relative
    // to it, the shape the unzip on the far side writes back.
    return ZipEncoder().encodeBytes(await archiveOf(_fs, [dir], base: dir));
  }

  @override
  Future<String> artifactPath(String chatId, String artifactId, {String? project}) async {
    project = project ?? await _projectOf(chatId);
    return config.artifactDir(chatId, artifactId, project: project);
  }

  @override
  Future<Uint8List?> readSkillInstall(String chatId, String installId) async {
    final project = await _projectOf(chatId);
    final dir = config.skillStagingDir(chatId, installId, project: project);
    final file = _fs.file(_fs.path.join(dir, "package.skill"));
    return await file.exists() ? file.readAsBytes() : null;
  }
}

/// Copy a directory's contents from [source] to [target]. If [source] is a
/// file rather than a directory, its parent is copied instead — the artifact
/// tool accepts either a dir path or a single `.html` file path. Subdirectories
/// are copied recursively. Works on any `FileSystem`, including IndexedDB.
Future<void> _copyDir(FileSystem fs, String source, String target) async {
  var dir = source;
  if (await fs.file(source).exists()) {
    dir = fs.path.dirname(source);
  }
  await fs.directory(target).create(recursive: true);
  await _copyDirContents(fs, dir, target);
}

Future<void> _copyDirContents(FileSystem fs, String source, String target) async {
  await for (final entity in fs.directory(source).list()) {
    final name = fs.path.basename(entity.path);
    final dest = fs.path.join(target, name);
    if (entity is File) {
      await fs.file(dest).writeAsBytes(await entity.readAsBytes());
    } else if (entity is Directory) {
      await fs.directory(dest).create(recursive: true);
      await _copyDirContents(fs, entity.path, dest);
    }
  }
}
