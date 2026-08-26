import "dart:async";
import "dart:convert";

import "package:collection/collection.dart";
import "package:flutter/foundation.dart";
import "package:uuid/uuid.dart";

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/agent_backend.dart";
import "../../domain/ask.dart";
import "../../domain/chat_store.dart";
import "../../domain/file_tools.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../domain/prompt_library.dart";
import "../../domain/shell.dart";
import "../../domain/sub_agent_log.dart";
import "../../domain/tool_arg.dart";
import "../../domain/web_search.dart";
import "../local/file_sub_agent_log.dart";
import "builtin_agent.dart";
import "memory/instructions.dart";
import "memory/store.dart";
import "llm/gated_client.dart";
import "llm/llm_client.dart";
import "llm/llm_registry.dart";
import "llm/rate_limit_gate.dart";
import "permission_classifier.dart";
import "projection.dart";
import "sub_agent.dart";
import "task_tool.dart";
import "templates.dart";

/// The built-in agent, running in this process. The loop is [BuiltinAgent];
/// this is what Entoli talks to: it holds a session per chat, resolves which
/// endpoint a turn runs against, and hands the agent the message to run. What
/// the composer's `/` and `@` syntax meant is already on that message — see
/// "Commands and agents" in `lib/domain/CLAUDE.md`.
class BuiltinBackend implements AgentBackend {
  BuiltinBackend({
    required this.config,
    required this.registry,
    required this.shell,
    required this.webSearch,
    required this.store,
    this.library,
    this.options = const BuiltinOptions(),
  });

  final AppConfig config;
  final LlmRegistry registry;
  final Shell shell;

  /// The chat store, which the agent writes artifacts to. Held here rather
  /// than passed per-turn: the store resolves which project a chat is in.
  final ChatStore store;

  /// Entoli's own commands and agents. A turn's own references travel on the
  /// message, resolved where it was composed, so this is left for the `task`
  /// tool — which names an `@agent` the user never wrote.
  final PromptLibrary? library;

  /// Web search and fetch, chosen by the platform like [shell] is:
  /// `DuckDuckGoSearch` on desktop and Android, `UnavailableWebSearch` in a
  /// browser. Named rather than defaulted because a default of the first would
  /// ship its HTML parser to every browser that loads the app and could never
  /// call it.
  final WebSearch webSearch;

  /// The notes the background memory writes add: the page of the chat they
  /// are about reads its own off the stream.
  final MemoryNotes _memoryNotes = MemoryNotes();

  /// One consolidation at a time: the interval is the real limit, and the
  /// flag is for the turn that finishes while the pass is still mid-call.
  bool _consolidating = false;

  @override
  Stream<MemoryNote> get memoryNotes => _memoryNotes.notes;

  /// Limits and timeouts for every turn.
  final BuiltinOptions options;

  @override
  ValueListenable<Set<String>> get runningTurns => _running;

  final Map<String, BuiltinSession> _sessions = {};
  final _RunningTurns _running = _RunningTurns();
  final Map<String, StreamController<AgentEvent>> _controllers = {};
  final Map<String, List<ToolApproval>> _approvals = {};
  /// One per approval on screen, created when the request is forwarded and
  /// completed by whichever comes first: the user's answer, or the turn ending.
  final Map<String, Completer<ApprovalResponse>> _pending = {};

  /// The same two, for the questions the model puts to the user.
  final Map<String, List<AskRequest>> _questions = {};
  final Map<String, Completer<List<String?>>> _answers = {};

  /// No directories yet: a chat nobody says anything in is never saved, and an
  /// empty `chats/<uuid>/` for each one would outlive it.
  @override
  Future<Chat> createChat({String? title}) async {
    final chatId = const Uuid().v4();
    final now = DateTime.now();
    return Chat(
      state: ChatState(
        id: chatId,
        title: title ?? "New chat",
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  @override
  Stream<AgentEvent> sendPrompt(
    String chatId,
    Message prompt, {
    List<Message> history = const [],
    TurnSettings settings = const TurnSettings(),
  }) =>
      _start(chatId, prompt, history: history, settings: settings);

  @override
  Stream<AgentEvent> resumeTurn(
    String chatId, {
    List<Message> history = const [],
    TurnSettings settings = const TurnSettings(),
  }) =>
      _start(chatId, null, history: history, settings: settings);

  /// The stream is returned rather than yielded, so the caller is listening
  /// before the turn starts: closing a controller nobody listens to never
  /// completes.
  Stream<AgentEvent> _start(
    String chatId,
    Message? prompt, {
    List<Message> history = const [],
    required TurnSettings settings,
  }) {
    final controller = StreamController<AgentEvent>();
    _controllers[chatId] = controller;
    unawaited(_runTurn(chatId, prompt, controller,
        history: history, settings: settings));
    return controller.stream;
  }

  /// [prompt] is the message the user sent, or null to carry on the turn
  /// [history] ends in. Everything either needs — the model, the directories, the gate, the
  /// sub-agent runner — is the same; they differ only in what the agent is
  /// asked and in how much of the session is rebuilt first.
  Future<void> _runTurn(
    String chatId,
    Message? prompt,
    StreamController<AgentEvent> controller, {
    List<Message> history = const [],
    required TurnSettings settings,
  }) async {
    final project = settings.project;
    try {
      // Before the model is resolved, because a `!` turn never needs one: a
      // chat with no provider configured can still run a command.
      if (prompt != null && shellBypassCommand(prompt.plainText) != null) {
        await _runBypass(chatId, prompt, controller,
            history: history,
            project: project,
            sharedWorkspace: settings.sharedWorkspace);
        return;
      }

      final target = _resolveModel(settings.model, settings.provider);
      if (target == null) {
        _fail(
            controller,
            settings.provider == null
                ? "No model is selected. Add a provider in Settings and pick one."
                : "'${settings.provider}' is not configured. Add it in Settings, "
                    "or pick another model.");
        return;
      }

      await config.ensureChatDirs(chatId, project: project);
      await config.ensureProjectDirs(project: project);
      final workspace = config.workspaceDir(chatId, project: project);
      final projectWorkspace = _projectWorkspaceFor(
          workspace: workspace,
          project: project,
          sharedWorkspace: settings.sharedWorkspace);
      // What this turn is offered: the device's facts minus a headless turn's
      // takes and the project's. One value, so the prompt and the tool list
      // cannot disagree.
      final caps = AgentCapabilities.forTurn(
        commands: shell.canRunCommands,
        webSearch: webSearch.available,
        disabled: settings.disabled,
      );
      // One gate per turn, shared by the parent and every sub-agent it spawns:
      // bounds in-flight stream() calls and coordinates 429 backoff so a
      // fan-out doesn't each-retry-into the same rate limit.
      final rateLimitGate = RateLimitGate(
        maxConcurrent: options.maxConcurrentLlmRequests,
        maxRetryBudget: options.rateLimitRetryBudget,
      );
      final gatedClient = GatedLlmClient(target.client, rateLimitGate);
      final subAgentLog = FileSubAgentLog(config, chatId, project: project);
      final subAgentRunner = SubAgentRunner(
        client: gatedClient,
        shell: shell,
        fs: config.fs,
        workspace: workspace,
        projectWorkspace: projectWorkspace,
        model: target.modelId,
        library: library,
        options: options,
        webSearch: webSearch,
        rateLimitGate: rateLimitGate,
        log: subAgentLog,
        caps: caps,
        sharedWorkspace: settings.sharedWorkspace,
      );
      final classifier =
          _resolveClassifier(settings.classifierProvider, settings.classifierModel);
      // The AGENTS.md block, loaded once where the two workspace paths are
      // known: the files are read into every turn, and the imports and
      // excludes answers are the only halves a turn may withhold. Empty when
      // nothing was found; the agent renders it either way.
      final instructions = await loadInstructions(
        config.fs,
        projectWorkspace: projectWorkspace,
        global: config.globalInstructionsFile,
        imports: settings.memory.imports,
        excludes: settings.memory.excludes,
      );
      // The project's memory store, when the subsystem runs at all. Which
      // project's is on the settings; the dir is never built twice for a
      // turn, so recall and the agent's tools share one.
      final memoryStore = settings.memory.autoMemory &&
              settings.memory.memoryDir != null
          ? MemoryStore(config.fs, settings.memory.memoryDir!)
          : null;
      // The memories this turn is about, rendered ready to read, and the
      // always-loaded half of the store: the pinned ones in full, and the
      // rest as an index. A store that will not answer recalls nothing and
      // costs the turn nothing: the memories are a convenience, not the turn.
      String recall = "";
      String pinned = "";
      String index = "";
      if (memoryStore != null && settings.memory.recall) {
        try {
          final all = await memoryStore.entries();
          pinned = renderPinned(all);
          index = renderIndex(
              [for (final entry in all) if (!entry.pinned) entry]);
          final query = (prompt ??
                  history.lastWhereOrNull((m) => m.role == MessageRole.user))
              ?.plainText ??
              "";
          if (query.isNotEmpty) {
            recall = renderRecall(await memoryStore.search(query));
          }
        } catch (e) {
          logFailure("memory", "recall failed: $e");
        }
      }
      // Before the session is built, so the revived results are in the history
      // it is projected from rather than patched in afterwards.
      if (prompt == null) {
        history = await _reviveSubAgents(history, subAgentRunner, subAgentLog, controller);
      }
      final session = await _sessionOf(chatId, history, rebuild: prompt == null);
      final agent = BuiltinAgent(
        session: session,
        loadResource: _resourcesOf(chatId),
        client: gatedClient,
        shell: shell,
        fs: config.fs,
        workspace: workspace,
        projectWorkspace: projectWorkspace,
        model: target.modelId,
        options: options,
        approveMode: settings.approveMode,
        classifier: classifier,
        approve: _awaitApproval,
        answer: _awaitAnswers,
        subAgentRunner: subAgentRunner,
        webSearch: webSearch,
        profile: settings.profile,
        rateLimitGate: rateLimitGate,
        memory: settings.memory,
        instructions: instructions,
        recall: recall,
        pinned: pinned,
        index: index,
        memoryStore: settings.memory.agentTool ? memoryStore : null,
        memoryChat: settings.memory.agentTool ? chatId : null,
        caps: caps,
        sharedWorkspace: settings.sharedWorkspace,
        saveArtifact: (path, {artifactId}) async {
          final resolved = resolveWorkspacePath(config.fs, path, workspace, projectWorkspace);
          if (artifactId != null) {
            await store.updateArtifact(chatId, artifactId, resolved, project: project);
            return artifactId;
          }
          return store.createArtifact(chatId, resolved, project: project);
        },
      );
      _running.add(chatId, agent.cancel);

      // A resumed turn has no prompt of its own to read `@agent` mentions out
      // of, so they come off the message that started it — its record of them,
      // not the library, so an agent edited or deleted since still carries on
      // under what the turn actually ran under.
      final said =
          prompt ?? history.lastWhereOrNull((m) => m.role == MessageRole.user);
      final agentPrompt = agentPromptFrom(said?.documents ?? const {});
      final events = prompt == null
          ? agent.resume(agentPrompt: agentPrompt)
          : agent.run(prompt, agentPrompt: agentPrompt);

      var reply = "";
      var endedDone = false;
      await for (final event in events) {
        if (controller.isClosed) break;
        if (event is TextDelta) reply += event.text;
        if (event is DoneEvent && !event.aborted) endedDone = true;
        if (event is ApprovalRequestEvent) {
          _approvals.putIfAbsent(chatId, () => []).add(event.approval);
          // Created here rather than where it is awaited: the banner is on
          // screen the moment this is forwarded, so the answer can beat the
          // agent to asking.
          _pending.putIfAbsent(event.approval.id, Completer.new);
        }
        if (event is QuestionRequestEvent) {
          _questions.putIfAbsent(chatId, () => []).add(event.request);
          _answers.putIfAbsent(event.request.id, Completer.new);
        }
        controller.add(event);
      }
      if (endedDone &&
          settings.memory.extract &&
          memoryStore != null &&
          settings.memory.bgModel != null) {
        // Unwatched on purpose: the turn is over, and the background memory
        // work must neither slow anything down nor be able to fail. The
        // consolidation rides behind the extraction rather than beside it —
        // the two would race over the store, and the call order is the
        // script's in a test.
        unawaited(_extractMemories(
          store: memoryStore,
          chatId: chatId,
          prompt: prompt,
          history: history,
          reply: reply,
          settings: settings,
        ).then((_) => _consolidateMemories(
            store: memoryStore, chatId: chatId, settings: settings)));
      }
    } catch (e) {
      _fail(controller, "$e");
    } finally {
      _clearApprovals(chatId);
      _clearQuestions(chatId);
      if (!controller.isClosed) await controller.close();
      // Last, after the stream is closed: dropping it here is what releases
      // Android's hold on the process, and the listener is still writing the
      // turn's closing records when the agent itself has stopped.
      _running.remove(chatId);
    }
  }

  /// Where a turn in [project] reaches for the project's files, and the
  /// `HOME` of its commands: the shared workspace where it is shared, the
  /// chat's own otherwise, so that nothing reaches past the conversation.
  String _projectWorkspaceFor({
    required String workspace,
    required String? project,
    required bool sharedWorkspace,
  }) =>
      sharedWorkspace ? config.projectWorkspaceDir(project: project) : workspace;

  /// Run what [prompt] says and be done: no model call, no tools, and no
  /// approval, since the user typed the command rather than being asked to
  /// allow one.
  Future<void> _runBypass(
    String chatId,
    Message prompt,
    StreamController<AgentEvent> controller, {
    required List<Message> history,
    required String? project,
    required bool sharedWorkspace,
  }) async {
    final command = shellBypassCommand(prompt.plainText)!;
    await config.ensureChatDirs(chatId, project: project);
    final workspace = config.workspaceDir(chatId, project: project);
    final run = shell.start(command,
        cwd: workspace,
        home: _projectWorkspaceFor(
            workspace: workspace,
            project: project,
            sharedWorkspace: sharedWorkspace),
        sharedHome: sharedWorkspace,
        timeout: options.commandTimeout);
    // Before the wait, so Stop kills the command rather than only closing the
    // stream over it.
    _running.add(chatId, run.kill);
    controller.add(StatusEvent(runningTool(bashToolName)));

    final result = await run.result;
    // An aborted turn writes no part, so the session must not hold one either.
    if (controller.isClosed) return;
    final part = ShellRunPart(
      command: command,
      returnCode: result.returnCode,
      output: result.output,
      exceptionInfo: result.exceptionInfo,
    );
    controller.add(ShellRunEvent(part));
    controller.add(const DoneEvent());
    // The same two functions a turn with a model in it uses, over the same one
    // part that was just reported: the prompt through `projectionOf`, the reply
    // through `assistantMessages`. The `!` turn writes its own reply, and that
    // is the only way it differs.
    final session = await _sessionOf(chatId, history);
    final opens = !session.hasConversation;
    session.messages
      ..addAll(await projectionOf([prompt],
          first: opens, load: _resourcesOf(chatId)))
      ..addAll(assistantMessages([part]));
  }

  /// The chat's session, filled from [history] where it is one this backend was
  /// not already holding — which is a chat opened after a restart, and empty.
  /// Filling it is what keeps the conversation going rather than starting it
  /// over. [rebuild] fills it whether or not it is empty, which a resume does
  /// so that carrying on in the same process and carrying on after a restart
  /// put the same thing in front of the model — a checkpoint that failed is
  /// swallowed, so a live session can hold more than the log does.
  Future<BuiltinSession> _sessionOf(String chatId, List<Message> history,
      {bool rebuild = false}) async {
    final session = _sessions.putIfAbsent(chatId, BuiltinSession.new);
    if (rebuild || session.isFresh) {
      session.replaceWith(
          await projectionOf(history, load: _resourcesOf(chatId)));
    }
    return session;
  }

  /// Where this chat's attachment bytes come from, for the projection.
  ResourceLoader _resourcesOf(String chatId) =>
      (resource) => store.readResource(chatId, resource);

  /// Carry on the sub-agents the interrupted turn left in flight. A `task`
  /// call whose result never landed is answered by reviving the sub-agent that
  /// was running it, rather than by the projection's "this was interrupted" —
  /// the parent asked for that work and is owed the answer, and the sub-agent's
  /// own transcript is right there to carry on from.
  ///
  /// Nothing asks the user, and nothing asks the model. Only the top of the
  /// conversation is the user's to resume; a sub-agent is machinery inside a
  /// turn they have already said to continue.
  ///
  /// A call with no transcript is left alone: it never started, so there is
  /// nothing to carry on and the projection's wording is the honest answer.
  Future<List<Message>> _reviveSubAgents(
    List<Message> history,
    SubAgentRunner runner,
    SubAgentLog log,
    StreamController<AgentEvent> controller,
  ) async {
    final reply = history.lastOrNull;
    if (reply == null || reply.role != MessageRole.assistant) return history;

    final answered = reply.parts.whereType<ToolResultPart>().map((p) => p.result.callId).toSet();
    final pending = reply.parts
        .whereType<ToolCallPart>()
        .where((p) => p.toolCall.name == taskToolName && !answered.contains(p.toolCall.id))
        .toList();
    if (pending.isEmpty) return history;

    final revived = await Future.wait(pending.map((part) async {
      final callId = part.toolCall.id;
      final agent = stringArg(part.toolCall.argumentsJson, "agent");
      if (agent == null || !await log.isResumable(callId)) return null;
      final result = await runner.resume(agent, callId);
      return ToolResult(
        callId: callId,
        returnCode: result.returnCode,
        output: result.output,
        exceptionInfo: result.exceptionInfo,
      );
    }));

    final results = revived.nonNulls.toList();
    if (results.isEmpty) return history;
    // Through the event stream like any other result, so the reply on screen
    // and the records in `conv.jsonl` both gain it without a second path.
    for (final result in results) {
      if (controller.isClosed) break;
      controller.add(ToolResultEvent(result));
    }
    return [
      ...history.take(history.length - 1),
      reply.copyWith(parts: [
        ...reply.parts,
        for (final result in results) MessagePart.toolResult(result: result),
      ]),
    ];
  }

  void _fail(StreamController<AgentEvent> controller, String message) {
    if (controller.isClosed) return;
    controller.add(ErrorEvent(message));
    controller.add(const DoneEvent());
  }

  /// Asked outside every chat's session, so this is never part of the
  /// conversation the agent is holding. The timeout is on the stream rather
  /// than the future it collects: a timed-out future leaves the response being
  /// read to nobody.
  @override
  Future<String?> ask(String prompt,
      {required String model, required String provider}) async {
    final target = _resolveModel(model, provider);
    if (target == null) return null;
    try {
      final chunks = await target.client
          .stream([LlmMessage(role: LlmRole.user, text: prompt)], model: target.modelId)
          .timeout(const Duration(seconds: 60))
          .toList();
      final answer = chunks.whereType<LlmCompletion>().lastOrNull?.message.text.trim();
      return answer == null || answer.isEmpty ? null : answer;
    } catch (_) {
      return null;
    }
  }

  /// What a turn that ended cleanly leaves behind: a background model reads
  /// the exchange and keeps the facts that outlive it. Runs unwatched, so it
  /// fails by writing nothing and leaving a line in the log — a turn is over
  /// when its last event is out, whatever this is still doing.
  Future<void> _extractMemories({
    required MemoryStore store,
    required String chatId,
    required Message? prompt,
    required List<Message> history,
    required String reply,
    required TurnSettings settings,
  }) async {
    final target =
        _resolveModel(settings.memory.bgModel, settings.memory.bgProvider);
    if (target == null) return;
    final said = (prompt ??
            history.lastWhereOrNull((m) => m.role == MessageRole.user))
        ?.plainText ??
        "";
    final replyText = reply.trim();
    if (said.trim().isEmpty && replyText.isEmpty) return;
    // What is already kept, the newest first — the ones a new exchange is
    // most likely to restate or spend. The ids ride with them: they are the
    // handles for the replaces and delete keys. A store that will not answer
    // is no better than an empty one.
    String existing = "";
    try {
      existing = renderRecall([...(await store.entries())].reversed.toList(),
          withIds: true);
    } catch (e) {
      logFailure("memory", "could not read the store for extraction: $e");
    }
    final question = "Here is an exchange between a user and an assistant:\n\n"
        "User: $said\n\n"
        "Assistant: $replyText\n\n"
        "${existing.isEmpty ? "" : "Memories already kept about this project:\n$existing\n\n"}"
        "Maintain the memory: from the exchange, keep the facts that would "
        "still be true and useful in a later conversation — a preference the "
        "user stated, a decision that was made, a fact learned about a "
        "codebase, an account, or the user. One fact per entry, each in one or "
        "two sentences, written so it makes sense without this exchange. Never "
        "include secrets, keys, or credentials, and never include what a file "
        "would say. Reply with JSON only: {\"memories\": [\"...\"], "
        "\"replaces\": {\"<id>\": \"...\"}, \"delete\": [\"<id>\"]}, where "
        "memories is a new fact, replaces corrects one of the ones above by "
        "its id, and delete spends one the exchange contradicts or supersedes. "
        "Any key may be an empty list where there is nothing to do.";
    try {
      final chunks = await target.client
          .stream([LlmMessage(role: LlmRole.user, text: question)],
              model: target.modelId)
          .timeout(const Duration(seconds: 60))
          .toList();
      final answer =
          chunks.whereType<LlmCompletion>().lastOrNull?.message.text.trim() ?? "";
      final ops = _maintainFrom(answer);
      if (ops.add.isEmpty && ops.replaces.isEmpty && ops.delete.isEmpty) return;
      final result = await store.maintain(
        delete: ops.delete,
        replaces: ops.replaces,
        add: ops.add,
        chat: chatId,
      );
      if (result.added > 0) {
        _memoryNotes.add(MemoryNote(chatId, result.added == 1
            ? "Kept 1 memory."
            : "Kept ${result.added} memories."));
      }
    } catch (e) {
      logFailure("memory", "extraction failed: $e");
    }
  }

  /// The slow half of the memory's housekeeping: where extraction keeps what
  /// one exchange is worth, consolidation tidies what the store has grown
  /// into — the duplicates an exchange at a time leaves behind, the entries a
  /// newer one superseded. It rides extraction's gate and runs unwatched like
  /// it, but earns its model call with a threshold: a store grown past
  /// [consolidationMinEntries], at most one pass per
  /// [consolidationMinInterval], one at a time. A tidy store says nothing on
  /// success, and a failure is a log line like any other background failure.
  Future<void> _consolidateMemories({
    required MemoryStore store,
    required String chatId,
    required TurnSettings settings,
  }) async {
    if (_consolidating) return;
    _consolidating = true;
    try {
      final target =
          _resolveModel(settings.memory.bgModel, settings.memory.bgProvider);
      if (target == null) return;
      final all = await store.entries();
      // Pinned memories are the user's standing orders rather than store
      // growth: the pass neither sees them nor may spend them.
      final offered = [for (final entry in all) if (!entry.pinned) entry];
      if (offered.length < consolidationMinEntries) return;
      final now = DateTime.now();
      final last = await store.lastConsolidated();
      if (last != null && now.difference(last) < consolidationMinInterval) {
        return;
      }
      final question = "Memories kept about this project:\n"
          "${renderConsolidation(offered)}\n\n"
          "Tidy these memories. Merge two entries that say the same thing by "
          "rewriting one with the merged wording and spending the other; spend "
          "an entry that is plainly superseded or contradicted by a newer one; "
          "and leave everything else exactly as it is. Only what is listed "
          "decides: never delete or change an entry on a guess, and where two "
          "entries could be read either way, keep both. Reply with JSON only: "
          "{\"memories\": [...], \"replaces\": {\"<id>\": \"...\"}, "
          "\"delete\": [\"<id>]}, where replaces rewrites an entry by its id, "
          "delete spends one, and memories is empty unless the merge leaves "
          "behind a fact none of the entries held. If nothing is wrong, all "
          "three empty.";
      try {
        final chunks = await target.client
            .stream([LlmMessage(role: LlmRole.user, text: question)],
                model: target.modelId)
            .timeout(const Duration(seconds: 60))
            .toList();
        final answer =
            chunks.whereType<LlmCompletion>().lastOrNull?.message.text.trim() ?? "";
        final ops = _maintainFrom(answer);
        if (ops.add.isNotEmpty ||
            ops.replaces.isNotEmpty ||
            ops.delete.isNotEmpty) {
          final pinned = {for (final entry in all) if (entry.pinned) entry.id};
          await store.maintain(
            delete: [for (final id in ops.delete) if (!pinned.contains(id)) id],
            replaces: {
              for (final e in ops.replaces.entries)
                if (!pinned.contains(e.key)) e.key: e.value,
            },
            add: ops.add,
            chat: chatId,
          );
        }
        // The interval is owed whatever the pass found: an hour with nothing
        // to tidy is an hour of not asking again.
        await store.stampConsolidated(now);
      } catch (e) {
        logFailure("memory", "consolidation failed: $e");
      }
    } finally {
      _consolidating = false;
    }
  }

  /// The maintenance JSON, read as liberally as the model writes it: the old
  /// shape — an array of strings, or an object holding one — reads as new
  /// facts, and the object adds the replaces and delete keys. What is not a
  /// string where a string is owed is nothing, because that is all the store
  /// takes.
  ({List<String> add, Map<String, String> replaces, List<String> delete})
      _maintainFrom(String answer) {
    const empty = (
      add: <String>[],
      replaces: <String, String>{},
      delete: <String>[],
    );
    Object? decoded;
    try {
      decoded = jsonDecode(answer.trim());
    } catch (_) {
      final fenced = RegExp(r"```(?:json)?\n([\s\S]*?)```").firstMatch(answer);
      if (fenced == null) return empty;
      try {
        decoded = jsonDecode(fenced.group(1)!.trim());
      } catch (_) {
        return empty;
      }
    }
    if (decoded is List) {
      return (add: _factsFrom(decoded), replaces: const {}, delete: const []);
    }
    if (decoded is! Map) return empty;
    final replaces = <String, String>{};
    final rawReplaces = decoded["replaces"];
    if (rawReplaces is Map) {
      for (final entry in rawReplaces.entries) {
        if (entry.key is! String || entry.value is! String) continue;
        var text = (entry.value as String).trim();
        if (text.isEmpty) continue;
        if (text.length > recallEntryChars) {
          text = text.substring(0, recallEntryChars);
        }
        replaces[entry.key as String] = text;
      }
    }
    final memories = decoded["memories"] ?? decoded["add"];
    return (
      add: memories is List ? _factsFrom(memories) : const [],
      replaces: replaces,
      delete: decoded["delete"] is List
          ? _stringsFrom(decoded["delete"] as List)
          : const [],
    );
  }

  /// The new-fact half of the answer: trimmed, cut to the store's write cap,
  /// and at most five of them, the way the old shape was.
  List<String> _factsFrom(Object? value) {
    final facts = <String>[];
    for (final entry in (value as List)) {
      if (entry is! String) continue;
      var text = entry.trim();
      if (text.isEmpty) continue;
      if (text.length > recallEntryChars) {
        text = text.substring(0, recallEntryChars);
      }
      facts.add(text);
      if (facts.length == 5) break;
    }
    return facts;
  }

  List<String> _stringsFrom(Object? value) => [
        for (final entry in (value as List))
          if (entry is String) entry,
      ];

  /// The config is read once and reused: going back through the registry by id
  /// would re-read and re-parse `settings.json` for each question asked of it.
  ({LlmClient client, String modelId})? _resolveModel(String? model, String? provider) {
    if (provider == null) return null;
    final endpoint = registry.endpointFor(provider);
    if (endpoint == null) return null;
    final config = endpoint.config;
    // A provider with one model listed does not need it pinned as well; with
    // none, there is nothing to guess from.
    final modelId = model ?? config.models.firstOrNull;
    if (modelId == null || modelId.isEmpty) return null;
    return (client: registry.clientOf(endpoint), modelId: modelId);
  }

  /// The classifier model, resolved the same way the main model is. Null when
  /// no classifier model is named — auto mode falls back to asking.
  PermissionClassifier? _resolveClassifier(String? provider, String? model) {
    if (provider == null || model == null) return null;
    final target = _resolveModel(model, provider);
    if (target == null) return null;
    return LlmClassifier(client: target.client, model: target.modelId);
  }

  Future<ApprovalResponse> _awaitApproval(ToolApproval approval) =>
      _pending.putIfAbsent(approval.id, Completer.new).future;

  Future<List<String?>> _awaitAnswers(AskRequest request) =>
      _answers.putIfAbsent(request.id, Completer.new).future;

  /// A turn that ended with a question still on screen would leave the banner
  /// there and the next answer with nothing to answer.
  void _clearApprovals(String chatId) {
    for (final approval in _approvals.remove(chatId) ?? const <ToolApproval>[]) {
      final completer = _pending.remove(approval.id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(ApprovalResponse.deny);
      }
    }
  }

  /// Likewise for the panel: an abandoned turn answers its own questions with
  /// nothing rather than leaving the agent waiting on a screen that has gone.
  void _clearQuestions(String chatId) {
    for (final request in _questions.remove(chatId) ?? const <AskRequest>[]) {
      final completer = _answers.remove(request.id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(request.unanswered);
      }
    }
  }

  /// What is on screen for [chatId]. Not on `AgentBackend` — the UI tracks
  /// approvals from the event stream; this is for tests of this class.
  ///
  /// A copy: answering one removes it, and a caller that walks the list while
  /// answering each would be mutating what it is reading.
  @visibleForTesting
  Future<List<ToolApproval>> pendingApprovals(String chatId) async =>
      List.unmodifiable(_approvals[chatId] ?? const []);

  @visibleForTesting
  List<AskRequest> pendingQuestions(String chatId) =>
      List.unmodifiable(_questions[chatId] ?? const []);

  @override
  Future<void> respondApproval(
      String chatId, String approvalId, ApprovalResponse response) async {
    _approvals[chatId]?.removeWhere((a) => a.id == approvalId);
    // Completed in place rather than removed: the agent may not have got round
    // to awaiting it yet, and it has to find this answer rather than a fresh
    // completer nobody will ever complete. `_clearApprovals` does the removing.
    final completer = _pending[approvalId];
    if (completer != null && !completer.isCompleted) completer.complete(response);
  }

  @override
  Future<void> respondQuestions(
      String chatId, String requestId, List<String?> answers) async {
    _questions[chatId]?.removeWhere((r) => r.id == requestId);
    final completer = _answers[requestId];
    if (completer != null && !completer.isCompleted) completer.complete(answers);
  }

  @override
  Future<void> abort(String chatId) async {
    await _running.remove(chatId)?.call();
    _clearApprovals(chatId);
    _clearQuestions(chatId);
    final controller = _controllers.remove(chatId);
    if (controller != null && !controller.isClosed) {
      controller.add(const DoneEvent(aborted: true));
      await controller.close();
    }
  }

  @override
  Future<void> resetSession(String chatId, {List<Message> history = const []}) async {
    await _running.remove(chatId)?.call();
    _sessions
        .putIfAbsent(chatId, BuiltinSession.new)
        .replaceWith(await projectionOf(history, load: _resourcesOf(chatId)));
  }

  @override
  Future<void> disposeChat(String chatId) async {
    await abort(chatId);
    _sessions.remove(chatId);
  }

  /// Concurrently: this runs on the way out, and the app would otherwise wait
  /// out every live turn's process kill one after another.
  @override
  Future<void> shutdown() async {
    await Future.wait(_running.value.toList().map(abort));
    _sessions.clear();
    registry.close();
    webSearch.close();
    await _memoryNotes.close();
  }

  @override
  Future<List<ModelOption>> models() => registry.models();
}

/// The turns in flight, and which chats they belong to as that changes. One
/// object rather than a map beside a notifier: two structures kept in step by
/// hand are one forgotten update away from a foreground service that never goes
/// away.
class _RunningTurns extends ValueNotifier<Set<String>> {
  _RunningTurns() : super(const {});

  /// How to stop each, rather than what is running it: an agent's own `cancel`
  /// for a turn the model is driving, the command's `kill` for a `!` one, and
  /// nothing here has to tell them apart.
  final Map<String, Future<void> Function()> _stops = {};

  void add(String chatId, Future<void> Function() stop) {
    _stops[chatId] = stop;
    value = _stops.keys.toSet();
  }

  /// Publishes only where something was actually removed: `abort` reaches chats
  /// with nothing running — deleting one does — and a `Set` compares by
  /// identity, so a fresh one would notify every time and cost a round trip to
  /// the platform to stop a service that was never started.
  Future<void> Function()? remove(String chatId) {
    final stop = _stops.remove(chatId);
    if (stop != null) value = _stops.keys.toSet();
    return stop;
  }
}
