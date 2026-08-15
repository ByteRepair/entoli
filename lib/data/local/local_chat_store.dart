import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:path/path.dart" as p;

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
  Future<List<ChatSummary>> list() async {
    if (!config.chatsDir.existsSync()) return [];
    final entries = config.chatsDir.listSync().whereType<Directory>();
    final summaries = <ChatSummary>[];
    for (final dir in entries) {
      final id = p.basename(dir.path);
      final stateFile = config.stateFile(id);
      if (!stateFile.existsSync()) continue;
      try {
        final json = jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
        final state = ChatState.fromJson(json);
        summaries.add(ChatSummary(
          id: state.id,
          title: state.title,
          createdAt: state.createdAt,
          updatedAt: state.updatedAt,
          backend: state.backend,
          model: state.model,
        ));
      } catch (_) {}
    }
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return summaries;
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
  Future<String> saveResource(String chatId, String filename, Uint8List bytes, String mimeType) async {
    final dir = config.resourcesDir(chatId);
    var safeName = filename.replaceAll(RegExp(r"[^A-Za-z0-9._-]"), "_");
    safeName = safeName.replaceAll(RegExp(r"\.{2,}"), ".");
    if (safeName.startsWith(".")) safeName = safeName.substring(1);
    final file = File(p.join(dir.path, safeName));
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  @override
  Future<ChatMeta> loadMeta(String chatId) async => ChatMeta.fromFile(config.metaFile(chatId));

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async {
    config.ensureChatDirs(chatId);
    await meta.saveTo(config.metaFile(chatId));
  }
}