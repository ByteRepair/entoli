import "../domain/agent_backend.dart";
import "../domain/app_settings.dart";
import "../domain/chat_meta.dart";
import "../domain/chat_store.dart";
import "../domain/models.dart";

/// Owns the mapping between on-disk chats and live agent sessions.
/// Writes `conv.json` after every turn; reads it on load and re-injects
/// context into the backend so `conv.json` stays the source of truth.
class ChatRepository {
  ChatRepository(this._store, this._backend, this._settings);

  final ChatStore _store;
  final AgentBackend _backend;

  /// Read on use, not captured: the app default changes while this lives.
  final AppSettings Function() _settings;

  Future<List<ChatSummary>> listChats() => _store.list();

  Future<Chat> createChat({String? title}) async {
    final chat = await _backend.createChat(
      title: title,
      model: _settings().defaultModelId,
      provider: _settings().defaultProviderId,
    );
    await _store.save(chat);
    return chat;
  }

  Future<Chat> openChat(String id) => _store.load(id);

  Future<void> save(Chat chat) => _store.save(chat);

  Future<ChatMeta> loadMeta(String chatId) => _store.loadMeta(chatId);

  Future<void> saveMeta(String chatId, ChatMeta meta) => _store.saveMeta(chatId, meta);

  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const []}) async* {
    final meta = await _store.loadMeta(chatId);
    // The chat's own choice wins, else the app default, else whatever the
    // backend picks. Never mix halves: a chat's model under the app default's
    // provider is not a combination anyone asked for.
    final model = meta.model ?? _settings().defaultModelId;
    final provider = meta.model != null ? meta.provider : _settings().defaultProviderId;
    yield* _backend.sendPrompt(chatId, text,
        attachments: attachments, model: model, provider: provider);
  }

  /// Forget the message at [index] and everything after it, then give the
  /// backend a session that never saw them.
  Future<Chat> rewind(Chat chat, int index) async {
    final kept = chat.messages.sublist(0, index);
    final truncated = chat.copyWith(messages: kept);
    await _store.save(truncated);
    await _backend.resetSession(chat.state.id, history: kept);
    return truncated;
  }

  Future<void> abort(String chatId) => _backend.abort(chatId);

  Future<void> deleteChat(String id) async {
    await _backend.disposeChat(id);
    await _store.delete(id);
  }

  Future<void> deleteAllChats() async {
    final chats = await listChats();
    await Future.wait(chats.map((c) => deleteChat(c.id)));
  }

  Future<void> renameChat(String id, String title) async {
    final chat = await _store.load(id);
    await _store.save(chat.copyWith(
      state: chat.state.copyWith(title: title),
    ));
  }

  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse r) =>
      _backend.respondApproval(chatId, approvalId, r);

  Future<List<ToolApproval>> pendingApprovals(String chatId) => _backend.pendingApprovals(chatId);
}