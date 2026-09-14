import "dart:async";
import "dart:typed_data";

import "package:uuid/uuid.dart";

import "../core/config.dart";
import "../domain/agent_backend.dart";
import "../domain/app_settings.dart";
import "../domain/builtin_project.dart";
import "../domain/chat_log.dart";
import "../domain/chat_meta.dart";
import "../domain/chat_store.dart";
import "../domain/chat_title.dart";
import "../domain/models.dart";
import "../domain/permission.dart";
import "../domain/project.dart";
import "../domain/project_settings.dart";
import "../domain/prompt_library.dart";
import "../domain/shell.dart";
import "../domain/temp_chat_ttl.dart";

/// What changed on disk, as [ChatRepository.changes] reports it. The sync
/// layer's whole view of this device: everything a mirror needs to follow.
///
/// The repository knows nothing about who listens; the stream is broadcast,
/// and nobody subscribed is the ordinary case for every test that predates
/// sync.
sealed class RepoEvent {
  const RepoEvent();
}

class Appended extends RepoEvent {
  const Appended(this.chatId, this.records);

  final String chatId;
  final List<ChatRecord> records;
}

class StateChanged extends RepoEvent {
  const StateChanged(this.state);

  final ChatState state;
}

class MetaChanged extends RepoEvent {
  const MetaChanged(this.chatId, this.meta);

  final String chatId;
  final ChatMeta meta;
}

class Deleted extends RepoEvent {
  const Deleted(this.chatId);

  final String chatId;
}

class Moved extends RepoEvent {
  const Moved(this.chatId, this.project);

  final String chatId;
  final String? project;
}

/// The UI's door to storage and the agent. Resolves which model a chat runs
/// on, and owns which thread of a conversation is being read. The turn itself
/// is accumulated and saved by `ChatController` as events arrive.
class ChatRepository {
  ChatRepository(
    this._store,
    this._backend,
    this._settings,
    this._config, {
    PromptLibrary Function(String? project)? libraryFor,
  }) : _libraryFor = libraryFor ?? ((_) => PromptLibrary.empty);

  final ChatStore _store;
  final AgentBackend _backend;

  /// Read on use, not captured: the app default changes while this lives.
  final AppSettings Function() _settings;

  /// Where project settings live. Read on use, like [_settings].
  final AppConfig _config;

  /// Resolves the library a message's references are composed against, by
  /// project. See [composeUserPrompt].
  final PromptLibrary Function(String? project) _libraryFor;

  final _changes = StreamController<RepoEvent>.broadcast();

  /// Everything written through this repository, as it lands.
  Stream<RepoEvent> get changes => _changes.stream;

  Future<List<ChatState>> listChats() => _store.list();

  /// Make a chat and write it. **Callers create one only when there is
  /// something to put in it** — the new-chat screen as the first message is
  /// sent, voice mode on the way in, a reminder as it fires — so a screen
  /// nobody used leaves nothing behind. See "Starting a chat, and naming it".
  ///
  /// The model is deliberately not pinned: a chat with nothing in its
  /// `meta.json` follows the app default wherever it moves. [project] is,
  /// because it is where the chat's files go — null is the default project.
  /// [meta] is the settings it should run its first turn under, for a caller
  /// that decided them before there was a chat to hang them on — the reminder
  /// that pins `approveMode`, and the new-chat screen's own settings page.
  Future<Chat> createChat({String? title, String? project, ChatMeta? meta}) async {
    final base = await _backend.createChat(title: title);
    final chat = base.copyWith(state: base.state.copyWith(project: project));
    // Only where there is a meta to place: the store learns where a chat lives
    // from its first `saveState`, and a meta written before that goes under
    // the default project whatever [project] says. With none, this write is
    // the anchored one below over again.
    if (meta != null && !meta.isEmpty) {
      await _store.saveState(chat.state);
      await _store.saveMeta(chat.state.id, meta);
    }
    return chat.copyWith(state: await saveState(chat.state));
  }

  Future<List<String>> listProjects() => _store.listProjects();

  /// A name the user may create: [isProjectName] is the gate, and the app's
  /// own projects — the default's and the built-ins' — are not among them.
  Future<void> createProject(String name) {
    if (!isProjectName(name)) {
      throw ArgumentError.value(name, "name", "not a project name");
    }
    return _store.createProject(name);
  }

  /// The chats go with it, so their sessions are dropped the way deleting one
  /// at a time would drop them. Only a user's project can be deleted; the app's
  /// own cannot be.
  Future<void> deleteProject(String name) async {
    if (!isProjectName(name)) {
      throw ArgumentError.value(name, "name", "not a project name");
    }
    for (final chat in await listChats()) {
      if (chat.project == name) await _backend.disposeChat(chat.id);
    }
    await _store.deleteProject(name);
  }

  /// File a chat under another project. Its own workspace travels with it; the
  /// shared one it can reach is the new project's from the next turn on. A
  /// turn still running is ended first — it holds the directories that are
  /// about to move, and the next command it ran would quietly remake them
  /// under the project it left. The shell it stood in ends with the move, for
  /// the project it left: the next turn starts one in the new one.
  Future<void> moveChat(String chatId, String? project) async {
    final from = await _store.projectOf(chatId);
    if (from != project) {
      await abort(chatId);
      _backend.closeChatShell(chatId, project: from);
    }
    await _store.moveChat(chatId, project);
    _changes.add(Moved(chatId, project));
  }

  Future<Chat> openChat(String id) => _store.load(id);

  /// Write `state.json` and the directories under it. Called at the head of
  /// every turn, not only the first, and from the TTL propagation helpers when
  /// a setting change re-anchors chats. The conversation is deliberately not
  /// written here: it arrives as records, through [append].
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
  ///
  /// Returns what was written, anchor and all, since it is not what was passed
  /// in and a caller showing the chat has to draw the difference.
  Future<ChatState> saveState(ChatState state, {bool reanchor = false}) async {
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
    _changes.add(StateChanged(anchored));
    return anchored;
  }

  /// Re-anchor every chat in a project to now, so a project-level TTL change
  /// is reflected immediately. Null is the default project.
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
  Future<void> append(String chatId, List<ChatRecord> records) async {
    await _store.append(chatId, records);
    _changes.add(Appended(chatId, records));
  }

  /// A title change on its own — the title and nothing else. The conversation
  /// is deliberately not written: a turn may still be adding to it.
  Future<void> retitle(String chatId, String title) async {
    await _store.retitle(chatId, title);
    // A mirror is sent the whole state, and only the store knows the rest of
    // it: the caller's copy is older than the turn writing beside it.
    final renamed = await _store.loadState(chatId);
    if (renamed != null) _changes.add(StateChanged(renamed));
  }

  /// A name for a new chat, from the first thing said in it. Null when no
  /// title provider is configured: naming chats is off, and this one keeps the
  /// name it was created with. A provider named without a model resolves to
  /// its light default in the backend.
  ///
  /// A `!` message names nothing either. It is not a thing said, and it is the
  /// one turn the user routed away from a model — in a chat that may have no
  /// provider configured at all.
  Future<String?> suggestTitle(String text) async {
    final settings = _settings();
    final provider = settings.titleProviderId;
    final model = settings.titleModelId;
    if (provider == null || text.trim().isEmpty) return null;
    if (shellBypassCommand(text) != null) return null;
    final answer = await _backend.ask(titlePrompt(text), model: model, provider: provider);
    return answer == null ? null : cleanTitle(answer);
  }

  Future<ChatMeta> loadMeta(String chatId) => _store.loadMeta(chatId);

  Future<void> saveMeta(String chatId, ChatMeta meta) async {
    await _store.saveMeta(chatId, meta);
    _changes.add(MetaChanged(chatId, meta));
  }

  Future<ChatState?> loadState(String chatId) => _store.loadState(chatId);

  /// The chat's raw log, in order — what [openChat] replays and discards. The
  /// sync layer streams these to a mirror asking to follow from where it
  /// already is.
  Future<List<ChatRecord>> readRecords(String chatId) => _store.readRecords(chatId);

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
  Stream<AgentEvent> sendPrompt(String chatId, Message prompt,
      {List<Message> history = const [],
      bool replaces = false,
      String? omadaMember}) async* {
    if (replaces) await _backend.resetSession(chatId, history: history);
    yield* _backend.sendPrompt(chatId, prompt,
        history: history,
        settings: await _turnSettings(chatId, omadaMember: omadaMember));
  }

  /// Carry on the turn [history] ends in — see `AgentBackend.resumeTurn`. It
  /// runs under whatever the chat's settings are now, not whatever they were
  /// when the turn was cut off: the same rule an edit or a regenerate follows.
  Stream<AgentEvent> resumeTurn(String chatId,
      {List<Message> history = const [], String? omadaMember}) async* {
    yield* _backend.resumeTurn(chatId,
        history: history,
        settings: await _turnSettings(chatId, omadaMember: omadaMember));
  }

  /// The chat's own choice wins, else the app default, else whatever the
  /// backend picks. Never mix halves: a chat's model under the app default's
  /// provider is not a combination anyone asked for.
  ///
  /// Where the chat is in a built-in project, the project's spec answers for
  /// its profile, its memory and its workspace, and the takes on top — a
  /// headless turn's, where it parks on nothing — so a turn in one runs under
  /// whatever the app ships it with, whatever the settings say. A chat's own
  /// `memoryOff` is one of those takes: it turns the subsystem off for this
  /// chat alone, and where the project already took it away it cannot be given
  /// it back from here. `headless` is the other: a chat nobody watches (a
  /// reminder's) drops `ask_user` and `task`, since nobody is there to answer.
  Future<TurnSettings> _turnSettings(String chatId, {String? omadaMember}) async {
    final meta = await loadMeta(chatId);
    final settings = _settings();
    final project = await projectOf(chatId);
    final builtIn = builtinProjectOf(project);
    final disabled = {...builtIn?.disabled ?? const <AgentCapability>{}};
    if (meta.headless == true) {
      disabled..add(AgentCapability.ask)..add(AgentCapability.task);
    }
    final projectSettings = await projectSettingsOf(project);
    // In an Omada-on project, members are brought in by mentioning them —
    // their turn follows — so the `task` relay has no job left. The capability
    // mechanism drops it from the tool list and the prompt together.
    final omada = projectSettings.omada;
    if (omada) disabled.add(AgentCapability.task);
    return TurnSettings(
      model: meta.model ?? settings.defaultModelId,
      provider: meta.model != null ? meta.provider : settings.defaultProviderId,
      project: project,
      approveMode: meta.approveMode ?? settings.approveMode,
      classifierProvider: settings.classifierProviderId,
      classifierModel: settings.classifierModelId,
      profile: profileUnder(builtIn, appProfile: settings.profile),
      memory: builtIn?.memory == MemoryPolicy.off || meta.memoryOff == true
          ? MemorySettings.off
          : await _resolveMemory(settings, project),
      sharedWorkspace: builtIn?.sharedWorkspace ?? true,
      disabled: disabled,
      bundledInstructions: builtIn?.bundledInstructions,
      includesUserInstructions: builtIn?.includesUserInstructions ?? false,
      // The project's own command variables, beside the app-level ones.
      environment: projectSettings.environment ?? const {},
      // Chat rules first, then project, then app: a later rule wins only by
      // strength (deny over ask over allow), and the tiers break the tie.
      permissions: [
        ...meta.permissions,
        ...projectSettings.permissions,
        ...settings.permissions,
      ],
      // The project's writable roots, plus what the chat's and the project's
      // rules themselves grant — a rule that allows writing somewhere carries
      // the sandbox grant with it.
      writableDirs: [
        ...projectSettings.writableDirs,
        for (final rule in [...meta.permissions, ...projectSettings.permissions])
          ...rule.writes,
      ],
      sandboxReprompt: projectSettings.sandboxReprompt,
      turnMaxSteps:
          projectSettings.turnMaxSteps ?? settings.turnMaxSteps,

      // The answering member is the caller's fact, not the chat's — it is
      // about the message the turn runs, not the settings it runs under.
      omadaMember: omadaMember,
      omada: omada,
    );
  }

  /// Which memories a turn reads and writes: the app-level gates over which
  /// project's store answers. A non-default project with its own toggle on
  /// keeps a store of its own; every other chat shares the default project's.
  /// Both halves of the background model travel together or not at all, and
  /// until one is picked nothing in the subsystem writes. With the master
  /// off there is no store and the value carries nothing, but it is built
  /// rather than skipped: the AGENTS.md files a turn reads do not ride on it.
  Future<MemorySettings> _resolveMemory(AppSettings settings, String? project) async {
    String? dir;
    if (settings.autoMemory) {
      var owner = project;
      if (owner != null && !(await projectSettingsOf(owner)).useProjectMemory) {
        owner = null;
      }
      dir = _config.memoryDir(project: owner);
    }
    return MemorySettings(
      imports: settings.instructionImports,
      nested: settings.nestedInstructions,
      excludes: settings.instructionExcludes,
      autoMemory: settings.autoMemory,
      recall: settings.memoryRecall,
      extract: settings.memoryExtraction,
      agentTool: settings.memoryAgentTool,
      memoryDir: dir,
      bgModel: settings.memoryModelId,
      bgProvider: settings.memoryProviderId,
    );
  }

  /// A project's settings, read off `project.json` when they exist. The default
  /// project is null and lives in the data directory.
  Future<ProjectSettings> projectSettingsOf(String? project) async =>
      ProjectSettings.load(_config, project: project);

  /// Which TTL applies to a chat: its own choice wins, else the project's, else
  /// a built-in project's shipped default, else the app default. [project] is
  /// passed in by [saveState], which is holding the state it is about to write
  /// and so already knows; without it the answer is read back off disk.
  Future<TempChatTtl> _resolveTempTtl(String chatId, {String? project}) async {
    final meta = await loadMeta(chatId);
    if (meta.tempChatTtl != null) return meta.tempChatTtl!;
    final proj = project ?? await projectOf(chatId);
    final projectSettings = await projectSettingsOf(proj);
    if (projectSettings.tempChatTtl != null) return projectSettings.tempChatTtl!;
    final builtInTtl = builtinProjectOf(proj)?.tempChatTtl;
    if (builtInTtl != null) return builtInTtl;
    return _settings().tempChatTtl;
  }

  /// Which project a chat's files are in.
  Future<String?> projectOf(String chatId) => _store.projectOf(chatId);

  /// **The one place a user's message is made.** What they typed, the files it
  /// carries, and what its `/command` and `@agent` references meant when they
  /// sent it — resolved here, against the library as it is now, and never
  /// looked up again. A message built anywhere else would carry no references
  /// and quietly send the four characters the user typed; see "Commands and
  /// agents" in `lib/domain/CLAUDE.md`.
  ///
  /// [files] are already under the chat's `resources/`: the composer saves what
  /// it is holding with [saveAttachments] first, and a resend passes on the
  /// parts the message it branches from already had.
  Message composeUserPrompt(String text,
      {String? project, List<MessagePart> files = const []}) =>
      Message(
        id: const Uuid().v4(),
        role: MessageRole.user,
        createdAt: DateTime.now(),
        // Files first, the order they are sent in and a resend rebuilds.
        parts: [...files, MessagePart.text(text: text)],
        documents: promptDocuments(text, _libraryFor(project)),
      );

  /// Save what the user attached and describe it as the parts that outlive the
  /// turn. Only the composer has bytes to save: a message being resent already
  /// has its parts and passes those along instead.
  Future<List<MessagePart>> saveAttachments(String chatId, List<Attachment> attachments) =>
      Future.wait(attachments.map((a) async => MessagePart.file(
            resource: await _store.saveResource(chatId, a.filename, a.bytes),
            filename: a.filename,
            mimeType: a.mimeType,
          )));

  Future<Uint8List?> readResource(String chatId, String resource) =>
      _store.readResource(chatId, resource);

  /// A whole artifact as one zip — what a peer's `resourceRequest` naming one
  /// is answered with. Null where there is no artifact by that id.
  Future<Uint8List?> readArtifactZip(String chatId, String artifactId) =>
      _store.readArtifactZip(chatId, artifactId);

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
    await _backend.disposeChat(id);
    await _store.delete(id);
    _changes.add(Deleted(id));
  }

  Future<void> deleteAllChats() async {
    final chats = await listChats();
    await Future.wait(chats.map((c) => deleteChat(c.id)));
  }

  /// Delete every expired chat except [exceptId] (the one currently open, which
  /// is handled by the on-open prompt). Called at startup and on a 30-minute
  /// timer.
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
  Future<ChatState> keepExpiredChat(String chatId, ChatState state) async {
    final meta = await loadMeta(chatId);
    meta.tempChatTtl = TempChatTtl.off;
    await saveMeta(chatId, meta);
    return saveState(state.copyWith(tempTtlSince: null, tempTtlExpiresAt: null));
  }

  /// Pin a chat. Pinned chats sit under a "Pinned" heading in the sidebar and
  /// cannot be temporary: the TTL anchor is cleared and the chat's override is
  /// set to off so `saveState`'s resolution keeps it that way. The chat-level
  /// override is written even when it already resolved to off, so a later
  /// app/project change cannot revive the expiry under a pinned chat.
  Future<ChatState> pinChat(String chatId, ChatState state) async {
    final meta = await loadMeta(chatId);
    meta.tempChatTtl = TempChatTtl.off;
    await saveMeta(chatId, meta);
    return saveState(state.copyWith(
      pinned: true,
      tempTtlSince: null,
      tempTtlExpiresAt: null,
    ));
  }

  /// Unpin a chat. The TTL override set by [pinChat] stays, so the chat remains
  /// non-temporary; the chat settings page offers the TTL combobox again, with
  /// `Off` selected, and the user can re-enable temporary from there.
  Future<ChatState> unpinChat(String chatId, ChatState state) =>
      saveState(state.copyWith(pinned: false));

  /// Answer an approval banner. An "always" answer derives the standing rule
  /// from the approval — the command's leading words, the file's directory, or
  /// the fetch's host — writes it to the tier the answer names, and forwards
  /// the answer whole: the waiting turn derives the same rule for itself, so
  /// the rest of it is covered before the persisted file is read again. The
  /// project is the chat's own, read from the store — a UI snapshot may be
  /// from before a move.
  Future<void> respondApproval(
    String chatId,
    String approvalId,
    ApprovalResponse r, {
    ToolApproval? approval,
  }) async {
    if (r == ApprovalResponse.alwaysAllowChat ||
        r == ApprovalResponse.alwaysAllowProject) {
      final rule = ruleFromApproval(approval);
      if (rule != null) {
        if (r == ApprovalResponse.alwaysAllowChat) {
          await _saveChatRule(chatId, rule);
        } else {
          await _saveProjectRule(await projectOf(chatId), rule);
        }
      }
    }
    await _backend.respondApproval(chatId, approvalId, r);
  }

  /// Writes [rule] onto the chat's `meta.json`, read fresh — the turn that is
  /// running may have written the TTL or the anchor since the UI read it.
  Future<void> _saveChatRule(String chatId, PermissionRule rule) async {
    final meta = await _store.loadMeta(chatId);
    await _store.saveMeta(chatId, meta..permissions = [...meta.permissions, rule]);
    _changes.add(MetaChanged(chatId, meta));
  }

  /// Writes [rule] onto the project's `project.json`, read fresh; null is the
  /// default project's file.
  Future<void> _saveProjectRule(String? project, PermissionRule rule) async {
    final settings = ProjectSettings.load(_config, project: project);
    settings.permissions = [...settings.permissions, rule];
    await settings.save(_config, project: project);
  }

  Future<void> respondQuestions(String chatId, String requestId, List<String?> answers) =>
      _backend.respondQuestions(chatId, requestId, answers);
}