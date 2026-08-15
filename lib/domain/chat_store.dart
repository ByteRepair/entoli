import "dart:typed_data";

import "../domain/chat_meta.dart";
import "../domain/models.dart";

/// Persistent on-disk store for chats. Implements `state.json` + `conv.json`
/// layout under the data directory.
abstract class ChatStore {
  Future<List<ChatState>> list();

  Future<Chat> load(String id);

  Future<void> save(Chat chat);

  Future<void> delete(String id);

  /// Save an attachment's bytes under `resources/` and return the name they
  /// were stored under — unique, so two turns can attach the same filename.
  Future<String> saveResource(String chatId, String filename, Uint8List bytes);

  /// Read back what [saveResource] stored. Null once the file is gone.
  Future<Uint8List?> readResource(String chatId, String resource);

  Future<ChatMeta> loadMeta(String chatId);

  Future<void> saveMeta(String chatId, ChatMeta meta);
}