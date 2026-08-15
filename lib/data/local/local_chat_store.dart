import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../domain/chat_meta.dart";
import "../../domain/chat_store.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";

/// Filesystem-backed `ChatStore` using `state.json` + `conv.json` under a
/// project's `chats/`.
class LocalChatStore implements ChatStore {
  LocalChatStore(this.config);

  final AppConfig config;

  /// Which project each chat is in. A chat is addressed by its id alone, so
  /// this is how its directory is found: [list] fills it, and an id it has
  /// never seen is looked for on disk.
  final Map<String, String?> _projects = {};

  @override
  Future<List<ChatState>> list() async {
    final chats = <ChatState>[
      for (final project in everyProject(await listProjects())) ..._listIn(project),
    ];
    chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return chats;
  }

  /// Where a chat was found wins over what its `state.json` says, so one moved
  /// by hand is in the project it was moved to.
  List<ChatState> _listIn(String? project) {
    final dir = config.chatsDir(project: project);
    if (!dir.existsSync()) return const [];
    final chats = <ChatState>[];
    for (final chatDir in dir.listSync().whereType<Directory>()) {
      final state = _readState(p.basename(chatDir.path), project);
      if (state != null) chats.add(state);
    }
    return chats;
  }

  ChatState? _readState(String id, String? project) {
    final file = config.stateFile(id, project: project);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      _projects[id] = project;
      return ChatState.fromJson(json).copyWith(project: project);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> listProjects() async => _projectNames();

  List<String> _projectNames() {
    if (!config.projectsDir.existsSync()) return const [];
    return config.projectsDir
        .listSync()
        .whereType<Directory>()
        .map((dir) => p.basename(dir.path))
        .where(isProjectName)
        .toList()
      ..sort();
  }

  @override
  Future<String?> projectOf(String chatId) async => _projectOf(chatId);

  /// Where a chat's files already are, or null if it has none yet. Wrapped
  /// because being in the default project is `null` as well, and the two mean
  /// opposite things to a save.
  ({String? project})? _locate(String chatId) {
    if (_projects.containsKey(chatId)) return (project: _projects[chatId]);
    for (final project in everyProject(_projectNames())) {
      if (config.stateFile(chatId, project: project).existsSync()) {
        _projects[chatId] = project;
        return (project: project);
      }
    }
    return null;
  }

  /// A chat nothing has been written for is answered as the default project,
  /// which is where a new one goes unless it says otherwise.
  String? _projectOf(String chatId) => _locate(chatId)?.project;

  @override
  Future<void> createProject(String name) async =>
      config.ensureProjectDirs(project: name);

  @override
  Future<void> deleteProject(String name) async {
    final dir = config.projectDir(project: name);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    _projects.removeWhere((_, project) => project == name);
  }

  @override
  Future<void> moveChat(String chatId, String? project) async {
    final from = config.chatDir(chatId, project: _projectOf(chatId));
    final to = config.chatDir(chatId, project: project);
    if (!from.existsSync() || from.path == to.path) return;
    config.ensureProjectDirs(project: project);
    from.renameSync(to.path);
    _projects[chatId] = project;
    // `state.json` names its project too, so a chat read straight off disk
    // still knows where it is.
    final state = _readState(chatId, project);
    if (state != null) await saveState(state);
  }

  @override
  Future<Chat> load(String id) async {
    final project = _projectOf(id);
    final stateJson =
        jsonDecode(config.stateFile(id, project: project).readAsStringSync())
            as Map<String, dynamic>;
    final state = ChatState.fromJson(stateJson).copyWith(project: project);
    final messages = <Message>[];
    final convFile = config.convFile(id, project: project);
    if (convFile.existsSync()) {
      final convJson = jsonDecode(convFile.readAsStringSync()) as Map<String, dynamic>;
      final list = convJson["messages"] as List? ?? [];
      messages.addAll(list.map((m) => Message.fromJson(m as Map<String, dynamic>)));
    }
    return Chat(state: state, messages: messages);
  }

  @override
  Future<void> save(Chat chat) async {
    await saveState(chat.state);
    // Asked after the state was written, which is what settles where the chat
    // lives.
    config
        .convFile(chat.state.id, project: _projectOf(chat.state.id))
        .writeAsStringSync(jsonEncode({
          "messages": chat.messages.map((m) => m.toJson()).toList(),
        }));
  }

  @override
  Future<void> saveState(ChatState state) async {
    // Where the chat already is wins: a copy held from before it was moved
    // would otherwise write a second one back where it used to be. Its own
    // project only says where a chat that is nowhere yet should go.
    final located = _locate(state.id);
    final project = located == null ? state.project : located.project;
    _projects[state.id] = project;
    config.ensureChatDirs(state.id, project: project);
    // Synchronous on purpose: callers (and their tests) treat a returned save
    // as durable, and these are small local files.
    config
        .stateFile(state.id, project: project)
        .writeAsStringSync(jsonEncode(state.copyWith(project: project).toJson()));
  }

  @override
  Future<void> delete(String id) async {
    final dir = config.chatDir(id, project: _projectOf(id));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    _projects.remove(id);
  }

  @override
  Future<String> saveResource(String chatId, String filename, Uint8List bytes) async {
    final project = _projectOf(chatId);
    config.ensureChatDirs(chatId, project: project);
    final resource = resourceName(filename);
    // Async, unlike the small JSON files above: an attachment is big enough
    // that reading or writing it would be felt as a dropped frame.
    await File(p.join(config.resourcesDir(chatId, project: project).path, resource))
        .writeAsBytes(bytes);
    return resource;
  }

  @override
  Future<Uint8List?> readResource(String chatId, String resource) async {
    final dir = config.resourcesDir(chatId, project: _projectOf(chatId));
    final file = File(p.join(dir.path, p.basename(resource)));
    return await file.exists() ? await file.readAsBytes() : null;
  }

  @override
  Future<ChatMeta> loadMeta(String chatId) async =>
      ChatMeta.fromFile(config.metaFile(chatId, project: _projectOf(chatId)));

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async {
    final project = _projectOf(chatId);
    config.ensureChatDirs(chatId, project: project);
    await meta.saveTo(config.metaFile(chatId, project: project));
  }
}
