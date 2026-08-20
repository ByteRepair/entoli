import "dart:typed_data";

import "../core/config.dart";
import "../domain/agent_backend.dart";
import "../domain/app_settings.dart";
import "../domain/chat_log.dart";
import "../domain/chat_meta.dart";
import "../domain/chat_store.dart";
import "../domain/chat_title.dart";
import "../domain/models.dart";
import "../domain/project_settings.dart";
import "../domain/shell.dart";
import "../domain/temp_chat_ttl.dart";

/// The UI's door to storage and the agent. Resolves which model a chat runs
/// on, and owns which thread of a conversation is being read. The turn itself
/// is accumulated and saved by `ChatController` as events arrive.
class ChatRepository {
  ChatRepository(this._store, this._backend, this._settings, this._config);

  final ChatStore _store;
  final AgentBackend _backend;

  /// Read on use, not captured: the app default changes while this lives.
  final AppSettings Function() _settings;

  /// Where project settings live. Read on use, like [_settings].
  final AppConfig _config;

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
  /// `meta.json` follows the app default wherever it moves. [project] is,
  /// because it is where the chat's files go — null is the default project.
  Future<Chat> createChat({String? title, String? project}) async {
    final chat = await _backend.createChat(title: title);
    _draft = chat.copyWith(state: chat.state.copyWith(project: project));
    _draftMeta = null;
    return _draft!;
  }

  Future<List<String>> listProjects() => _store.listProjects();

  Future<void> createProject(String name) => _store.createProject(name);

  /// The chats go with it, so their sessions are dropped the way deleting one
  /// at a time would drop them. A draft belonging to it goes too: it is not in
  /// the list, and the project it was to be written to is about to be gone.
  Future<void> deleteProject(String name) async {
    for (final chat in await listChats()) {
      if (chat.project == name) await _dropSession(chat.id);
    }
    if (_draft?.state.project == name) await _dropSession(_draft!.state.id);
    await _store.deleteProject(name);
  }

  /// File a chat under another project. Its own workspace travels with it; the
  /// shared one it can reach is the new project's from the next turn on.
  Future<void> moveChat(String chatId, String? project) =>
      _store.moveChat(chatId, project);

  Future<Chat> openChat(String id) async => _isDraft(id) ? _draft! : await _store.load(id);

  /// Write `state.json` and the directories under it, promoting the draft if it
  /// still is one — which is where whatever was pinned on it gets written too.
  /// Called at the head of every turn, not only the first, and from the TTL
  /// propagation helpers when a setting change re-anchors chats. The
  /// conversation is deliberately not written here: it arrives as records,
  /// through [append].
  ///
  /// Also maintains the chat's TTL anchor: the resolved TTL is recomputed on
  /// every save so widening the app/project window extends an existing chat
  /// from its original anchor. `tempTtlSince` is set once when the TTL is
  /// enabled and cleared when it goes back to off; `tempTtlExpiresAt` is
  /// `since + duration`, recomputed each save.
  ///
  /// [reanchor] resets `tempTtlSince` to now when the TTL is non-off, rather
  /// than preserving an existing anchor. Used by the propagation helpers when a
  /// setting change is the source of truth — flipping the app TTL on should
  /// anchor every chat to now, not keep one from 23h ago. The turn path leaves
  /// it false: a turn does not change the TTL, so the anchor is preserved.
  Future<void> saveState(ChatState state, {bool reanchor = false}) async {
    final pinned = _isDraft(state.id) ? _draftMeta : null;
    _forgetDraft(state.id);
    final ttl = await _resolveTempTtl(state.id, project: state.project);
    final dur = tempChatTtlDuration(ttl);
    DateTime? since = state.tempTtlSince;
    DateTime? expiresAt = state.tempTtlExpiresAt;
    if (dur == null) {
      since = null;
      expiresAt = null;
    } else {
      since = reanchor ? DateTime.now() : (since ?? DateTime.now());
      expiresAt = since.add(dur);
    }
    final anchored = state.copyWith(tempTtlSince: since, tempTtlExpiresAt: expiresAt);
    await _store.saveState(anchored);
    if (pinned != null) await _store.saveMeta(state.id, pinned);
  }

  /// Re-anchor every chat in a project to now, so a project-level TTL change
  /// is reflected immediately. Null is the default project. Drafts are not on
  /// disk and are skipped by [listChats].
  Future<void> reanchorProjectTtl(String? project) async {
    final chats = await listChats();
    await Future.wait([
      for (final c in chats.where((c) => c.project == project)) saveState(c, reanchor: true),
    ]);
  }

  /// Re-anchor every chat, in every project, to now. Called when the app-level
  /// TTL changes.
  Future<void> reanchorAllTtl() async {
    final chats = await listChats();
    await Future.wait(chats.map((c) => saveState(c, reanchor: true)));
  }

  /// Add to a chat's log. What a running turn does with everything it produces,
  /// and the only way a conversation is written.
  Future<void> append(String chatId, List<ChatRecord> records) =>
      _store.append(chatId, records);

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
  ///
  /// A `!` message names nothing either. It is not a thing said, and it is the
  /// one turn the user routed away from a model — in a chat that may have no
  /// provider configured at all.
  Future<String?> suggestTitle(String text) async {
    final settings = _settings();
    final provider = settings.titleProviderId;
    final model = settings.titleModelId;
    if (provider == null || model == null || text.trim().isEmpty) return null;
    if (shellBypassCommand(text) != null) return null;
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

  /// [history] is what was said before this prompt, for a backend that is not
  /// holding the chat's session — see `AgentBackend.sendPrompt`. It comes from
  /// the caller rather than being read back here: the turn's own records are
  /// still on their way to the store.
  ///
  /// [replaces] says the turn stands in for one already in the conversation —
  /// beside it as a thread, or in place of it — so the session the backend
  /// holds is a conversation this prompt does not continue. It rides with the
  /// prompt for the reason [history] does: a separate "forget what you were
  /// told" call is one a caller can forget, and forgetting it is silent, the
  /// model answering fluently from the turn the user has just left.
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const [],
      List<Message> history = const [],
      bool replaces = false}) async* {
    if (replaces) await _backend.resetSession(chatId, history: history);
    yield* _backend.sendPrompt(chatId, text,
        attachments: attachments,
        history: history,
        settings: await _turnSettings(chatId));
  }

  /// Carry on the turn [history] ends in — see `AgentBackend.resumeTurn`. It
  /// runs under whatever the chat's settings are now, not whatever they were
  /// when the turn was cut off: the same rule an edit or a regenerate follows.
  Stream<AgentEvent> resumeTurn(String chatId,
      {List<Message> history = const []}) async* {
    yield* _backend.resumeTurn(chatId,
        history: history, settings: await _turnSettings(chatId));
  }

  /// The chat's own choice wins, else the app default, else whatever the
  /// backend picks. Never mix halves: a chat's model under the app default's
  /// provider is not a combination anyone asked for.
  Future<TurnSettings> _turnSettings(String chatId) async {
    final meta = await loadMeta(chatId);
    final settings = _settings();
    final project = await projectOf(chatId);
    return TurnSettings(
      model: meta.model ?? settings.defaultModelId,
      provider: meta.model != null ? meta.provider : settings.defaultProviderId,
      project: project,
      approveMode: meta.approveMode ?? settings.approveMode,
      classifierProvider: settings.classifierProviderId,
      classifierModel: settings.classifierModelId,
      // A project can override the app-level profile; null falls back to it.
      profile: (await projectSettingsOf(project)).profile ?? settings.profile,
    );
  }

  /// A project's settings, read off `project.json` when they exist. The default
  /// project is null and lives in the data directory.
  Future<ProjectSettings> projectSettingsOf(String? project) async =>
      ProjectSettings.load(_config, project: project);

  /// Which TTL applies to a chat: its own choice wins, else the project's, else
  /// the app default. [project] is passed in for the draft case, which has no
  /// disk location to be found from; for a stored chat it is read back.
  Future<TempChatTtl> _resolveTempTtl(String chatId, {String? project}) async {
    final meta = await loadMeta(chatId);
    if (meta.tempChatTtl != null) return meta.tempChatTtl!;
    final proj = project ?? await projectOf(chatId);
    final projectSettings = await projectSettingsOf(proj);
    if (projectSettings.tempChatTtl != null) return projectSettings.tempChatTtl!;
    return _settings().tempChatTtl;
  }

  /// Which project a chat's files are in. A draft is not on disk to be found,
  /// so it answers for itself.
  Future<String?> projectOf(String chatId) async =>
      _isDraft(chatId) ? _draft!.state.project : await _store.projectOf(chatId);

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

  /// Read [messageId] rather than the thread beside it that is on screen.
  Future<Chat> selectThread(Chat chat, String messageId) =>
      _rethread(chat, ChatRecord.select(messageId: messageId));

  /// Delete the thread [messageId] heads, and everything below it. The last one
  /// at a branch can go too: what is left is the conversation cut off there,
  /// which is what this record meant before there were threads.
  Future<Chat> deleteThread(Chat chat, String messageId) =>
      _rethread(chat, ChatRecord.rewind(messageId: messageId));

  /// Append a record that changes which thread is being read, and load back
  /// what the log now says. Reading it again rather than working it out here:
  /// which messages a branch leaves live is `replayTree`'s to answer, and a
  /// second version of that walk is a second version to disagree.
  Future<Chat> _rethread(Chat chat, ChatRecord record) async {
    await append(chat.state.id, [record]);
    final now = await openChat(chat.state.id);
    // A session is the conversation the model has seen, and which conversation
    // that is has just changed.
    await _backend.resetSession(chat.state.id, history: now.messages);
    return now;
  }

  Future<void> abort(String chatId) => _backend.abort(chatId);

  Future<void> deleteChat(String id) async {
    await _dropSession(id);
    await _store.delete(id);
  }

  /// Everything a chat holds outside the store: the draft it may still be, and
  /// the live session the backend is keeping for it.
  Future<void> _dropSession(String id) async {
    _forgetDraft(id);
    await _backend.disposeChat(id);
  }

  Future<void> deleteAllChats() async {
    final chats = await listChats();
    await Future.wait(chats.map((c) => deleteChat(c.id)));
  }

  /// Delete every expired chat except [exceptId] (the one currently open, which
  /// is handled by the on-open prompt). Called at startup and on a 30-minute
  /// timer. Drafts are never swept — they are not on disk and have no state.
  Future<void> sweepExpired({String? exceptId}) async {
    final chats = await listChats();
    await Future.wait([
      for (final c in chats)
        if (c.id != exceptId && c.isExpired()) deleteChat(c.id),
    ]);
  }

  /// Keep an expired chat by turning its TTL off — overriding any project/app
  /// setting — and clearing the anchor and expiry. The on-open prompt's "keep"
  /// answer; the "delete" answer is [deleteChat]. The TTL override lives here
  /// beside [saveState]'s anchoring, so the rules about it stay in one place.
  Future<void> keepExpiredChat(String chatId, ChatState state) async {
    final meta = await loadMeta(chatId);
    meta.tempChatTtl = TempChatTtl.off;
    await saveMeta(chatId, meta);
    await saveState(state.copyWith(tempTtlSince: null, tempTtlExpiresAt: null));
  }

  /// Pin a chat. Pinned chats sit under a "Pinned" heading in the sidebar and
  /// cannot be temporary: the TTL anchor is cleared and the chat's override is
  /// set to off so `saveState`'s resolution keeps it that way. The chat-level
  /// override is written even when it already resolved to off, so a later
  /// app/project change cannot revive the expiry under a pinned chat.
  Future<void> pinChat(String chatId, ChatState state) async {
    final meta = await loadMeta(chatId);
    meta.tempChatTtl = TempChatTtl.off;
    await saveMeta(chatId, meta);
    await saveState(state.copyWith(
      pinned: true,
      tempTtlSince: null,
      tempTtlExpiresAt: null,
    ));
  }

  /// Unpin a chat. The TTL override set by [pinChat] stays, so the chat remains
  /// non-temporary; the chat settings page offers the TTL combobox again, with
  /// `Off` selected, and the user can re-enable temporary from there.
  Future<void> unpinChat(String chatId, ChatState state) async {
    await saveState(state.copyWith(pinned: false));
  }

  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse r) =>
      _backend.respondApproval(chatId, approvalId, r);

  Future<void> respondQuestions(String chatId, String requestId, List<String?> answers) =>
      _backend.respondQuestions(chatId, requestId, answers);
}