import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../../core/config.dart";
import "../../domain/chat_meta.dart";
import "../../domain/chat_store.dart";
import "../../domain/models.dart";

/// Filesystem-backed `ChatStore` using `state.json` + `conv.json` under
/// `AppConfig.chatsDir`.
class LocalChatStore implements ChatStore {
  LocalChatStore(this.config);

  final AppConfig config;

  @override
  Future<List<ChatState>> list() async {
    if (!config.chatsDir.existsSync()) return [];
    final chats = <ChatState>[];
    for (final dir in config.chatsDir.listSync().whereType<Directory>()) {
      final stateFile = config.stateFile(p.basename(dir.path));
      if (!stateFile.existsSync()) continue;
      try {
        chats.add(ChatState.fromJson(
          jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>,
        ));
      } catch (_) {}
    }
    chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return chats;
  }

  @override
  Future<Chat> load(String id) async {
    final stateJson = jsonDecode(config.stateFile(id).readAsStringSync()) as Map<String, dynamic>;
    final state = ChatState.fromJson(stateJson);
    final messages = <Message>[];
    final convFile = config.convFile(id);
    if (convFile.existsSync()) {
      final convJson = jsonDecode(convFile.readAsStringSync()) as Map<String, dynamic>;
      final list = convJson["messages"] as List? ?? [];
      messages.addAll(list.map((m) => Message.fromJson(m as Map<String, dynamic>)));
    }
    return Chat(state: state, messages: messages);
  }

  @override
  Future<void> save(Chat chat) async {
    final id = chat.state.id;
    config.ensureChatDirs(id);
    // Synchronous on purpose: callers (and their tests) treat a returned save
    // as durable, and these are small local files.
    config.stateFile(id).writeAsStringSync(jsonEncode(chat.state.toJson()));
    config.convFile(id).writeAsStringSync(jsonEncode({
      "messages": chat.messages.map((m) => m.toJson()).toList(),
    }));
  }

  @override
  Future<void> delete(String id) async {
    final dir = config.chatDir(id);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  @override
  Future<String> saveResource(String chatId, String filename, Uint8List bytes) async {
    config.ensureChatDirs(chatId);
    var safeName = filename.replaceAll(RegExp(r"[^A-Za-z0-9._-]"), "_");
    safeName = safeName.replaceAll(RegExp(r"\.{2,}"), ".");
    if (safeName.startsWith(".")) safeName = safeName.substring(1);
    final resource = "${const Uuid().v4()}-$safeName";
    // Async, unlike the small JSON files above: an attachment is big enough
    // that reading or writing it would be felt as a dropped frame.
    await File(p.join(config.resourcesDir(chatId).path, resource)).writeAsBytes(bytes);
    return resource;
  }

  @override
  Future<Uint8List?> readResource(String chatId, String resource) async {
    final file = File(p.join(config.resourcesDir(chatId).path, p.basename(resource)));
    return await file.exists() ? await file.readAsBytes() : null;
  }

  @override
  Future<ChatMeta> loadMeta(String chatId) async => ChatMeta.fromFile(config.metaFile(chatId));

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async {
    config.ensureChatDirs(chatId);
    await meta.saveTo(config.metaFile(chatId));
  }
}