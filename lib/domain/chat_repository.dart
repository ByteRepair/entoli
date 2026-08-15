import "dart:typed_data";

import "../domain/agent_backend.dart";
import "../domain/app_settings.dart";
import "../domain/chat_meta.dart";
import "../domain/chat_store.dart";
import "../domain/chat_title.dart";
import "../domain/models.dart";

/// The UI's door to storage and the agent. Resolves which model a chat runs
/// on, and owns rewinding a conversation. The turn itself is accumulated and
/// saved by `ChatController` as events arrive.
class ChatRepository {
  ChatRepository(this._store, this._backend, this._settings);

  final ChatStore _store;
  final AgentBackend _backend;

  /// Read on use, not captured: the app default changes while this lives.
  final AppSettings Function() _settings;

  /// A chat that has been started but not written to. It lives here until
  /// [save] puts it on disk, which the first turn does. Its settings come with
  /// it: writing `meta.json` would create the very directory a draft does
  /// without.
  Chat? _draft;
  ChatMeta? _draftMeta;

  bool _isDraft(String id) => _draft?.state.id == id;

  void _forgetDraft(String id) {
    if (!_isDraft(id)) return;
    _draft = null;
    _draftMeta = null;
  }

  Future<List<ChatState>> listChats() => _store.list();

  /// The model is deliberately not pinned here: a chat with nothing in its
  /// `meta.json` follows the app default wherever it moves.
  Future<Chat> createChat({String? title}) async {
    final chat = await _backend.createChat(title: title);
    _draft = chat;
    _draftMeta = null;
    return chat;
  }

  Future<Chat> openChat(String id) async => _isDraft(id) ? _draft! : await _store.load(id);

  /// Where a draft becomes a chat: whatever was pinned on it while it was one
  /// is written with it.
  Future<void> save(Chat chat) async {
    final pinned = _isDraft(chat.state.id) ? _draftMeta : null;
    _forgetDraft(chat.state.id);
    await _store.save(chat);
    if (pinned != null) await _store.saveMeta(chat.state.id, pinned);
  }

  /// A title change on its own. The conversation is deliberately not written:
  /// a turn may still be adding to it.
  Future<void> retitle(ChatState state, String title) async {
    final renamed = state.copyWith(title: title);
    if (_isDraft(state.id)) {
      _draft = _draft!.copyWith(state: renamed);
    } else {
      await _store.saveState(renamed);
    }
  }

  /// A name for a new chat, from the first thing said in it. Null when no
  /// title model is configured: naming chats is off, and this one keeps the
  /// name it was created with.
  Future<String?> suggestTitle(String text) async {
    final settings = _settings();
    final provider = settings.titleProviderId;
    final model = settings.titleModelId;
    if (provider == null || model == null || text.trim().isEmpty) return null;
    final answer = await _backend.ask(titlePrompt(text), model: model, provider: provider);
    return answer == null ? null : cleanTitle(answer);
  }

  Future<ChatMeta> loadMeta(String chatId) async =>
      _isDraft(chatId) ? _draftMeta ??= ChatMeta() : await _store.loadMeta(chatId);

  Future<void> saveMeta(String chatId, ChatMeta meta) async {
    if (_isDraft(chatId)) {
      _draftMeta = meta;
      return;
    }
    await _store.saveMeta(chatId, meta);
  }

  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const []}) async* {
    final meta = await loadMeta(chatId);
    // The chat's own choice wins, else the app default, else whatever the
    // backend picks. Never mix halves: a chat's model under the app default's
    // provider is not a combination anyone asked for.
    final model = meta.model ?? _settings().defaultModelId;
    final provider = meta.model != null ? meta.provider : _settings().defaultProviderId;
    yield* _backend.sendPrompt(chatId, text,
        attachments: attachments,
        model: model,
        provider: provider,
        approveCommands: meta.approveCommands ?? _settings().approveCommands);
  }

  /// Save what the user attached and describe it as the parts that outlive the
  /// turn. One already on disk stays where it is, so resending a message does
  /// not copy its bytes again.
  Future<List<MessagePart>> saveAttachments(String chatId, List<Attachment> attachments) =>
      Future.wait(attachments.map((a) async => MessagePart.file(
            resource: a.resource ?? await _store.saveResource(chatId, a.filename, a.bytes),
            filename: a.filename,
            mimeType: a.mimeType,
          )));

  /// What [message] carried, bytes and all, so the turn can be sent again. A
  /// resource that has gone missing is dropped.
  Future<List<Attachment>> loadAttachments(String chatId, Message message) async {
    final loaded = await Future.wait(message.files.map((part) async {
      final bytes = await _store.readResource(chatId, part.resource);
      return bytes == null
          ? null
          : Attachment(
              filename: part.filename,
              mimeType: part.mimeType,
              bytes: bytes,
              resource: part.resource,
            );
    }));
    return loaded.nonNulls.toList();
  }

  Future<Uint8List?> readResource(String chatId, String resource) =>
      _store.readResource(chatId, resource);

  /// Forget the message at [index] and everything after it, then give the
  /// backend a session that never saw them.
  Future<Chat> rewind(Chat chat, int index) async {
    final kept = chat.messages.sublist(0, index);
    final truncated = chat.copyWith(messages: kept);
    await save(truncated);
    await _backend.resetSession(chat.state.id, history: kept);
    return truncated;
  }

  Future<void> abort(String chatId) => _backend.abort(chatId);

  /// How long a turn may say nothing before it is written off. See
  /// `AgentBackend.stallTimeout`.
  Duration get stallTimeout => _backend.stallTimeout;

  Future<void> deleteChat(String id) async {
    _forgetDraft(id);
    await _backend.disposeChat(id);
    await _store.delete(id);
  }

  Future<void> deleteAllChats() async {
    final chats = await listChats();
    await Future.wait(chats.map((c) => deleteChat(c.id)));
  }

  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse r) =>
      _backend.respondApproval(chatId, approvalId, r);
}