import "dart:typed_data";

import "package:uuid/uuid.dart";

import "../domain/chat_meta.dart";
import "../domain/models.dart";

/// Persistent on-disk store for chats. Implements `state.json` + `conv.json`
/// layout under the data directory.
abstract class ChatStore {
  /// Every chat, in every project. Each one says which it is in, so the UI can
  /// show one project's without asking again.
  Future<List<ChatState>> list();

  Future<Chat> load(String id);

  /// The projects that exist, by name, sorted. The default project is not one
  /// of them: it is `null`, and it is always there.
  Future<List<String>> listProjects();

  /// Which project a chat's files are in — the default one when it has none,
  /// which is also what an id nothing has been written under answers.
  Future<String?> projectOf(String chatId);

  Future<void> createProject(String name);

  /// Delete a project, its chats and its shared workspace.
  Future<void> deleteProject(String name);

  /// Move a chat, its conversation, its resources and its own workspace into
  /// [project] — null for the default one.
  Future<void> moveChat(String chatId, String? project);

  Future<void> save(Chat chat);

  /// Write `state.json` alone. A rename that went through [save] would write
  /// back the conversation it had read, over whatever a running turn has
  /// added since.
  Future<void> saveState(ChatState state);

  Future<void> delete(String id);

  /// Save an attachment's bytes under `resources/` and return the name they
  /// were stored under — unique, so two turns can attach the same filename.
  Future<String> saveResource(String chatId, String filename, Uint8List bytes);

  /// Read back what [saveResource] stored. Null once the file is gone.
  Future<Uint8List?> readResource(String chatId, String resource);

  Future<ChatMeta> loadMeta(String chatId);

  Future<void> saveMeta(String chatId, ChatMeta meta);
}

/// What [ChatStore.saveResource] stores an attachment under: unique, so two
/// turns can attach the same filename, and safe to be one — the disk store
/// writes it as a path, and both stores answer [ChatStore.readResource] with
/// the name they gave out.
String resourceName(String filename) {
  var safe = filename.replaceAll(RegExp(r"[^A-Za-z0-9._-]"), "_");
  safe = safe.replaceAll(RegExp(r"\.{2,}"), ".");
  if (safe.startsWith(".")) safe = safe.substring(1);
  return "${const Uuid().v4()}-$safe";
}