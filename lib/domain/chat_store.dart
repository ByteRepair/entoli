import "dart:typed_data";

import "package:uuid/uuid.dart";

import "../domain/chat_log.dart";
import "../domain/chat_meta.dart";
import "../domain/models.dart";

/// Persistent on-disk store for chats. Implements `state.json` + `conv.jsonl`
/// layout under the data directory.
abstract class ChatStore {
  /// Every chat, in every project. Each one says which it is in, so the UI can
  /// show one project's without asking again.
  Future<List<ChatState>> list();

  Future<Chat> load(String id);

  /// The chat's head without its conversation. [load] reads this and the log
  /// together; the sync layer wants them separately, since it sends the raw
  /// records on and has no use for the replay between them.
  Future<ChatState?> loadState(String id);

  /// The chat's raw log, in order — what [load] replays through `chatFrom`
  /// and discards. The sync layer streams these to mirrors, which run their
  /// own replay.
  Future<List<ChatRecord>> readRecords(String chatId);

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

  /// Add to the chat's log. The only way a conversation is written: records are
  /// appended and never rewritten, so a turn killed halfway keeps everything
  /// that had already happened. There is deliberately no whole-log write to go
  /// with it — one would be the truncation the format exists to avoid, and a
  /// conversation held in memory is `append(id, recordsOf(messages))`.
  Future<void> append(String chatId, List<ChatRecord> records);

  /// Write `state.json`, creating the chat's directories. Everything else about
  /// a chat is written by something that has already been through here.
  Future<void> saveState(ChatState state);

  /// Set a stored chat's title, leaving every other field as it is on disk —
  /// the namer's copy of the rest is older than the turn's own save. Does
  /// nothing for an id nothing has been written under.
  Future<void> retitle(String chatId, String title);

  Future<void> delete(String id);

  /// Save an attachment's bytes under `resources/` and return the name they
  /// were stored under — unique, so two turns can attach the same filename.
  Future<String> saveResource(String chatId, String filename, Uint8List bytes);

  /// Read back what [saveResource] stored. Null once the file is gone.
  Future<Uint8List?> readResource(String chatId, String resource);

  /// Copy a workspace directory (or a single file's parent) into a new
  /// `artifacts/<id>/` and return the generated id. The [sourceDir] is an
  /// absolute path already resolved by the caller — the backend resolves
  /// `project:` prefixes and workspace paths before reaching here.
  Future<String> createArtifact(String chatId, String sourceDir, {String? project});

  /// Replace the contents of an existing `artifacts/<id>/` with the files at
  /// [sourceDir]. Used when the model re-publishes with an `artifact_id`.
  Future<void> updateArtifact(String chatId, String artifactId, String sourceDir, {String? project});

  /// Read a file out of an artifact's directory. Null once the file is gone.
  Future<Uint8List?> readArtifactFile(
    String chatId, String artifactId, String relativePath, {String? project});

  /// The artifact's directory, for building a `file://` URL or serving over
  /// HTTP. Returns the path whether or not the directory exists — callers that
  /// need to verify it exists should use [readArtifactFile] instead.
  Future<String> artifactPath(String chatId, String artifactId, {String? project});

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