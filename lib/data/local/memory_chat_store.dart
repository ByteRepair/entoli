import "dart:typed_data";

import "../../domain/chat_meta.dart";
import "../../domain/chat_store.dart";
import "../../domain/models.dart";

/// The `ChatStore` a browser gets: there is no filesystem to write to, so a
/// chat lasts as long as the page does and a reload starts over.
///
/// The rules `LocalChatStore` reads off disk are held here as fields instead —
/// which project a chat is in is the one it was saved under, and that wins over
/// what a `ChatState` handed in says, the same way the directory a chat was
/// found in does.
class MemoryChatStore implements ChatStore {
  final Map<String, Chat> _chats = {};
  final Set<String> _projects = {};

  /// Held encoded, like the file it stands in for, so a caller that keeps a
  /// [ChatMeta] and changes it does not reach back into the store.
  final Map<String, Map<String, dynamic>> _meta = {};

  /// Keyed by chat and resource name together, so deleting a chat takes its
  /// attachments with it.
  final Map<(String, String), Uint8List> _resources = {};

  @override
  Future<List<ChatState>> list() async {
    final states = [for (final chat in _chats.values) chat.state];
    states.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return states;
  }

  @override
  Future<Chat> load(String id) async {
    final chat = _chats[id];
    if (chat == null) throw StateError("no chat $id");
    return chat;
  }

  @override
  Future<List<String>> listProjects() async => _projects.toList()..sort();

  @override
  Future<String?> projectOf(String chatId) async => _chats[chatId]?.state.project;

  @override
  Future<void> createProject(String name) async => _projects.add(name);

  @override
  Future<void> deleteProject(String name) async {
    _projects.remove(name);
    for (final id in _chats.keys.toList()) {
      if (_chats[id]!.state.project == name) await delete(id);
    }
  }

  @override
  Future<void> moveChat(String chatId, String? project) async {
    final chat = _chats[chatId];
    if (chat == null) return;
    _chats[chatId] = chat.copyWith(state: chat.state.copyWith(project: project));
  }

  @override
  Future<void> save(Chat chat) async => _put(chat.state, chat.messages);

  @override
  Future<void> saveState(ChatState state) async =>
      _put(state, _chats[state.id]?.messages ?? const []);

  /// Where the chat already is wins: a copy held from before it was moved would
  /// otherwise put it back. Its own project only says where a chat that is
  /// nowhere yet should go.
  void _put(ChatState state, List<Message> messages) {
    final held = _chats[state.id];
    final project = held == null ? state.project : held.state.project;
    _chats[state.id] = Chat(state: state.copyWith(project: project), messages: messages);
  }

  @override
  Future<void> delete(String id) async {
    _chats.remove(id);
    _meta.remove(id);
    _resources.removeWhere((key, _) => key.$1 == id);
  }

  @override
  Future<String> saveResource(String chatId, String filename, Uint8List bytes) async {
    final resource = resourceName(filename);
    _resources[(chatId, resource)] = bytes;
    return resource;
  }

  @override
  Future<Uint8List?> readResource(String chatId, String resource) async =>
      _resources[(chatId, resource)];

  @override
  Future<ChatMeta> loadMeta(String chatId) async => ChatMeta.fromJson(_meta[chatId] ?? const {});

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async => _meta[chatId] = meta.toJson();
}
