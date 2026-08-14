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
  final AppSettings _settings;
  final Map<String, Stream<AgentEvent>> _active = {};

  Future<List<ChatSummary>> listChats() => _store.list();

  Future<Chat> createChat({String? title, String? model, String? provider}) async {
    final effectiveModel = model ?? _settings.defaultModelId;
    final effectiveProvider = provider ?? _settings.defaultProviderId;
    final chat = await _backend.createChat(
      title: title,
      model: effectiveModel,
      provider: effectiveProvider,
    );
    await _store.save(chat);
    return chat;
  }

  Future<Chat> openChat(String id) => _store.load(id);

  Future<void> save(Chat chat) => _store.save(chat);

  Future<ChatMeta> loadMeta(String chatId) => _store.loadMeta(chatId);

  Future<void> saveMeta(String chatId, ChatMeta meta) => _store.saveMeta(chatId, meta);

  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const [], String? model, String? provider}) {
    // Fall back as a pair: a chat's model under the app default's provider
    // would be an invalid combination.
    final effectiveModel = model ?? _settings.defaultModelId;
    final effectiveProvider = model != null ? provider : _settings.defaultProviderId;
    final stream = _backend
        .sendPrompt(chatId, text,
            attachments: attachments, model: effectiveModel, provider: effectiveProvider)
        .asyncExpand((event) async* {
      yield event;
      if (event is DoneEvent) {
        final chat = await _store.load(chatId);
        await _store.save(chat);
      }
    });
    _active[chatId] = stream;
    return stream;
  }

  Future<void> resetSession(String chatId, {String? transcript}) =>
      _backend.resetSession(chatId, transcript: transcript);

  Future<void> abort(String chatId) async {
    await _backend.abort(chatId);
    _active.remove(chatId);
  }

  Future<void> deleteChat(String id) async {
    await _backend.disposeChat(id);
    await _store.delete(id);
  }

  Future<void> deleteAllChats() async {
    for (final chat in await listChats()) {
      await deleteChat(chat.id);
    }
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

  Future<List<ModelOption>> availableModels() => _backend.availableModels();
}