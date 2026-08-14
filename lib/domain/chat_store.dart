import "dart:typed_data";

import "../domain/chat_meta.dart";
import "../domain/models.dart";

/// Persistent on-disk store for chats. Implements `state.json` + `conv.json`
/// layout under the data directory.
abstract class ChatStore {
  Future<List<ChatSummary>> list();

  Future<Chat> load(String id);

  Future<void> save(Chat chat);

  Future<void> delete(String id);

  /// Save an attachment's bytes under `resources/` and return the path.
  Future<String> saveResource(String chatId, String filename, Uint8List bytes, String mimeType);

  Future<ChatMeta> loadMeta(String chatId);

  Future<void> saveMeta(String chatId, ChatMeta meta);
}