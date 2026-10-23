import "dart:async";
import "dart:convert";

import "package:collection/collection.dart";
import "package:flutter/foundation.dart";
import "package:uuid/uuid.dart";

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/agent_backend.dart";
import "../../domain/agent_browser.dart";
import "../../domain/trigger_manager.dart" show TriggerRegistryFactory;
import "../../domain/app_settings.dart";
import "../../domain/ask.dart";
import "../../domain/chat_log.dart" show replayTree;
import "../../domain/chat_store.dart";
import "../../domain/file_tools.dart";
import "../../domain/llm_provider.dart";
import "../../domain/local_model.dart" show isTitleOnlyModel;
import "../../domain/models.dart";
import "../../domain/model_registry.dart";
import "../../domain/permission.dart";
import "../../domain/prompt_library.dart";
import "../../domain/shell.dart";
import "../../domain/sub_agent_log.dart";
import "../../domain/tool_arg.dart";
import "../../domain/web_search.dart";
import "../local/file_sub_agent_log.dart";
import "../prompts/skill_package.dart";
import "builtin_agent.dart";
import "customization_tools.dart" show SettingsEditor;
import "compact_prompt.dart";
import "memory/instructions.dart";
import "memory/store.dart";
import "llm/gated_client.dart";
import "llm/llm_client.dart";
import "llm/openai_client.dart";
import "llm/text_only_client.dart";
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
/// "Commands and agents" in `lib/domain/AGENTS.md`.
class BuiltinBackend implements AgentBackend {
  BuiltinBackend({
    required this.config,
    required this.registry,
    required this.shell,
    required this.webSearch,
    this.browser = const UnavailableAgentBrowser(),
    required this.store,
    this.triggerRegistry,
    this.editSettings,
    this.options = const BuiltinOptions(),
  });

  final AppConfig config;
  final LlmRegistry registry;
  final Shell shell;

  /// The chat store, which the agent writes artifacts to. Held here rather
  /// than passed per-turn: the store resolves which project a chat is in.
  final ChatStore store;

  /// A chat-scoped registry per chat, built where a turn asks for one. Null
  /// where the app runs no trigger manager — every turn is then offered the
  /// trio nowhere, the same answer a missing artifact store is.
  final TriggerRegistryFactory? triggerRegistry;

  /// What the customization tools write the app's settings through. Null
  /// withholds them.
  final SettingsEditor? editSettings;

  /// Entoli's own skills and agents, per project. A turn's own references
  /// travel on the message, resolved where it was composed against the
  /// project's library, so this is left for the `task` tool — which names an
  /// `@agent` the user never wrote — and for the skills offered to the model.
  /// Mutable because the Skills page can change what is on disk and reload the
  /// library; a turn already running keeps what it started with, the way a
  /// running command keeps its environment.
  ///
  /// Keyed by project, `null` the default the way it is everywhere a project is
  /// named. A project inherits the default's set and overrides same-named
  /// entries of its own.
  final Map<String?, PromptLibrary> _libraries = {};
  void setLibrary(String? project, PromptLibrary library) =>
      _libraries[project] = library;
  PromptLibrary? libraryFor(String? project) =>
      _libraries[project] ?? _libraries[null];

  /// Web search and fetch, chosen by the platform like [shell] is:
  /// `DuckDuckGoSearch` on desktop and Android, `UnavailableWebSearch` in a
  /// browser. Named rather than defaulted because a default of the first would
  /// ship its HTML parser to every browser that loads the app and could never
  /// call it.
  final WebSearch webSearch;

  /// The browser the `browser_*` tools drive, one tab per chat. Its tools are
  /// offered on a turn where Settings > Agent Browser has picked one.
  final AgentBrowser browser;

  /// The notes the background memory writes add: the page of the chat they
  /// are about reads its own off the stream.
  final MemoryNotes _memoryNotes = MemoryNotes();

  /// One consolidation at a time: the interval is the real limit, and the
  /// flag is for the turn that finishes while the pass is still mid-call.
  bool _consolidating = false;

  @override
  Stream<MemoryNote> get memoryNotes => _memoryNotes.notes;

  @override
  final SubAgentFeed subAgents = SubAgentFeed();

  /// Limits and timeouts for every turn.
  final BuiltinOptions options;

  @override
  ValueListenable<Set<String>> get runningTurns => _running;

  final Map<String, BuiltinSession> _sessions = {};

  /// The newest usage each chat's model reported, in context tokens — the
  /// fact the auto-compact threshold reads, and what a backend that forgets
  /// on dispose must not keep. Not a session: it is the newest request's
  /// fact, not the conversation's, and the controller reads it the way the
  /// controller reads everything else of the backend — through the callback
  /// that reported it.
  final Map<String, int> _usage = {};

  /// The context window the chat's model stands in, as `modelInfoOf`
  /// named it when the request beside this entry ran — written where the
  /// usage is written, so the threshold answers both halves of itself from
  /// one pair of maps with no `meta.json` read on the settle path. Null
  /// where the registry knows nothing, which the caller reads as the
  /// settings' global guess.
  final Map<String, int?> _windows = {};
  final _RunningTurns _running = _RunningTurns();
  /// Every open turn stream per chat: a parallel round runs several at once.
  final Map<String, Set<StreamController<AgentEvent>>> _controllers = {};

  /// Turn streams being stopped, and when each turn has forwarded its last
  /// event — see [abort].
  final Set<StreamController<AgentEvent>> _stopping = {};
  final Map<StreamController<AgentEvent>, Completer<void>> _drained = {};

  @visibleForTesting
  int get openTurnStreams =>
      _controllers.values.fold(0, (n, set) => n + set.length);
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
    List<ConversationCompaction> compactions = const [],
    TurnSettings settings = const TurnSettings(),
    SteerInbox? steers,
  }) =>
      _start(chatId, prompt,
          history: history,
          compactions: compactions,
          settings: settings,
          steers: steers);

  @override
  Stream<AgentEvent> resumeTurn(
    String chatId, {
    List<Message> history = const [],
    List<ConversationCompaction> compactions = const [],
    TurnSettings settings = const TurnSettings(),
    SteerInbox? steers,
  }) =>
      _start(chatId, null,
          history: history,
          compactions: compactions,
          settings: settings,
          steers: steers);

  /// The stream is returned rather than yielded, so the caller is listening
  /// before the turn starts: closing a controller nobody listens to never
  /// completes.
  Stream<AgentEvent> _start(
    String chatId,
    Message? prompt, {
    List<Message> history = const [],
    List<ConversationCompaction> compactions = const [],
    required TurnSettings settings,
    SteerInbox? steers,
  }) {
    final controller = StreamController<AgentEvent>();
    (_controllers[chatId] ??= {}).add(controller);
    _drained[controller] = Completer();
    unawaited(_runTurn(chatId, prompt, controller,
        history: history,
        compactions: compactions,
        settings: settings,
        steers: steers));
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
    List<ConversationCompaction> compactions = const [],
    required TurnSettings settings,
    SteerInbox? steers,
  }) async {
    final project = settings.project;
    // Registered up front and removed by key in the finally: a parallel
    // round runs several turns of one chat, and a chat-keyed map would drop
    // the earlier kill.
    final stopKey = _running.add(chatId, () async {});
    try {
      // Before the model is resolved, because a `!` turn never needs one: a
      // chat with no provider configured can still run a command.
      if (prompt != null && shellBypassCommand(prompt.plainText) != null) {
        await _runBypass(chatId, prompt, controller, stopKey,
            history: history,
            project: project,
            sharedWorkspace: settings.sharedWorkspace,
            environment: settings.environment);
        return;
      }

      final target = _resolveModel(settings.model, settings.provider);
      if (target == null) {
        _fail(
            controller,
            settings.provider == null
                ? "No model is selected. Add a provider in Settings and pick one."
                : isTitleOnlyModel(settings.provider, settings.model)
                    ? "The Apple on-device model only names chats: its context "
                        "is too small for the agent. Pick another model for "
                        "this chat."
                    : "'${settings.provider}' is not configured. Add it in "
                        "Settings, or pick another model.");
        return;
      }

      await config.ensureChatDirs(chatId, project: project);
      await config.ensureProjectDirs(project: project);
      final workspace = config.workspaceDir(chatId, project: project);
      final projectWorkspace = _projectWorkspaceFor(
          workspace: workspace,
          project: project,
          sharedWorkspace: settings.sharedWorkspace);
      String resolvePath(String path) => resolveWorkspacePath(
          config.fs, path, workspace, projectWorkspace,
          guestRoot: shell.guestRoot, homePath: shell.homeFor(projectWorkspace));
      // What this turn is offered: the device's facts minus a headless turn's
      // takes and the project's. One value, so the prompt and the tool list
      // cannot disagree.
      final caps = AgentCapabilities.forTurn(
        commands: shell.canRunCommands,
        webSearch: webSearch.available,
        disabled: settings.disabled,
        browser: browser.configured,
      );
      // One gate per turn, shared by the parent and every sub-agent it spawns:
      // bounds in-flight stream() calls and coordinates 429 backoff so a
      // fan-out doesn't each-retry-into the same rate limit.
      final rateLimitGate = RateLimitGate(
        maxConcurrent: options.maxConcurrentLlmRequests,
        maxRetryBudget: options.rateLimitRetryBudget,
      );
      final gatedClient = GatedLlmClient(target.client, rateLimitGate);
      final subAgentLog =
          FileSubAgentLog(config, chatId, project: project, feed: subAgents);
      final subAgentRunner = SubAgentRunner(
        client: gatedClient,
        shell: shell,
        fs: config.fs,
        workspace: workspace,
        projectWorkspace: projectWorkspace,
        environment: settings.environment,
        model: target.modelId,
        library: libraryFor(project),
        options: options,
        webSearch: webSearch,
        rateLimitGate: rateLimitGate,
        log: subAgentLog,
        caps: caps,
        sharedWorkspace: settings.sharedWorkspace,
        permissions: settings.permissions,
        writableDirs: settings.writableDirs,
        project: project,
        tone: settings.tone,
        citations: settings.citations,
      );
      final classifier =
          _resolveClassifier(settings.classifierProvider, settings.classifierModel);
      // The AGENTS.md block, loaded once where the two workspace paths are
      // known: the files are read into every turn, and the imports and
      // excludes answers are the only halves a turn may withhold. Where the
      // turn's project ships a note of its own it stands in for the whole
      // block: no file is read, and nothing a file read would pull in can
      // either. Where it ships a note *and* asks for the user's instructions
      // (`includesUserInstructions`), the files are read after the note, so
      // the user's rules reach the turn and win on conflict. Started before
      // the recall reads below, which it is independent of: a turn's two file
      // loads are not a queue.
      final bundled = settings.bundledInstructions;
      final readFiles = bundled == null || settings.includesUserInstructions;
      final instructionsF = readFiles
          ? loadInstructions(
              config.fs,
              projectWorkspace: projectWorkspace,
              global: config.globalInstructionsFile,
              imports: settings.memory.imports,
              excludes: settings.memory.excludes,
            )
          : Future.value(const <InstructionFile>[]);
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
            recall = renderRecall(await memoryStore.search(query, entries: all));
          }
        } catch (e) {
          logFailure("memory", "recall failed: $e");
        }
      }
      final loaded = await instructionsF;
      // What the conversation has already recorded reading — one pass over the
      // history's parts, the claim set the label emission below spends. Derived
      // per turn rather than held on this object, so a rewind that takes a part
      // out of the history also takes the file back out of it, and re-running
      // the turn records the read again — the log as it now reads stays true.
      // Held state would drift from the log and lie; this cannot.
      final reached = {
        for (final m in history)
          for (final part in m.parts)
            if (part is InstructionsPart)
              for (final ref in part.files) ref.path,
      };

      // The read is the turn's own to claim, so it is claimed the moment the
      // load answers: what it claims is what the history does not yet name,
      // and two turns claiming the same new file would both have had to pass
      // this synchronous stretch — the serialized-dispatch case. Two members'
      // first turns dispatched in parallel each derive from a history that
      // predates the other's reply and could both label a file new; the
      // claim set answers for what the log can say, not for a window nobody
      // else on this path guards.
      // `add` answers what was new, and what was new is exactly what the
      // event says.
      final fresh = [
        for (final file in loaded)
          if (reached.add(file.path)) file.ref,
      ];
      if (fresh.isNotEmpty) controller.add(InstructionsReadEvent(fresh));
      final instructions = bundled == null
          ? loaded
          : [
              InstructionFile(
                path: settings.project ?? "the built-in project",
                kind: InstructionKind.bundled,
                content: bundled,
              ),
              if (settings.includesUserInstructions) ...loaded,
            ];
      // Before the session is built, so the revived results are in the history
      // it is projected from rather than patched in afterwards.
      if (prompt == null) {
        history = await _reviveSubAgents(history, subAgentRunner, subAgentLog, controller);
      }
      final session = await _sessionOf(chatId, history,
          rebuild: prompt == null,
          viewer: settings.omadaMember,
          compactions: compactions);
      final agent = BuiltinAgent(
        session: session,
        viewer: settings.omadaMember,
        loadResource: _resourcesOf(chatId),
        steers: steers,
        client: gatedClient,
        shell: shell,
        fs: config.fs,
        workspace: workspace,
        projectWorkspace: projectWorkspace,
        environment: settings.environment,
        model: target.modelId,
        // One attempt per request: the controller retries a failed turn itself,
        // and the two retrying would be the same patience twice. Sub-agents
        // keep the default — see the parent runner below. The step limit is
        // the turn's own, resolved per turn from the settings levels; null
        // leaves the backend's.
        options: options.copyWith(
            maxAttempts: 1, stepLimit: settings.turnMaxSteps),
        skills: libraryFor(settings.project)?.entries(CompletionKind.skill) ?? const [],
        // The room's participants, an omada turn's data alone: the library's
        // agents, already tier-walked (the default set under My Team's under
        // the project's own). Null keeps the tool off the list where there
        // is no room.
        roomParticipants: settings.omada
            ? libraryFor(settings.project)?.entries(CompletionKind.agent)
            : null,
        approveMode: settings.approveMode,
        classifier: classifier,
        approve: _awaitApproval,
        answer: _awaitAnswers,
        subAgentRunner: subAgentRunner,
        webSearch: webSearch,
        browser: caps.browser
            ? (browser.tab(chatId)
              ..downloadDir = config.fs.path.join(workspace, "downloads"))
            : null,
        seesImages: target.info?.readsImages ?? true,
        browserHidden: browser.hidden,
        browserUploads: AppSettings.load(config).agentBrowserUploads,
        browserApprove: switch (AppSettings.load(config).agentBrowserApproval) {
          BrowserApproval.never => ApproveMode.never,
          BrowserApproval.classifier => ApproveMode.auto,
          BrowserApproval.always => ApproveMode.ask,
        },
        profile: settings.profile,
        tone: settings.tone,
        citations: settings.citations,
        rateLimitGate: rateLimitGate,
        // A bundled turn's note is its whole instruction half, so the nested
        // walk on a read — the one memory answer the agent itself consults —
        // is off: there is no file anywhere to pull in.
        memory:
            bundled != null ? const MemorySettings(nested: false) : settings.memory,
        instructions: instructions,
        // Claims what a mid-turn read pulls in against the same set the
        // up-front load spent, so a file reached either way is recorded once.
        claimInstruction: reached.add,
        recall: recall,
        pinned: pinned,
        index: index,
        memoryStore: settings.memory.agentTool ? memoryStore : null,
        memoryChat: settings.memory.agentTool ? chatId : null,
        caps: caps,
        sharedWorkspace: settings.sharedWorkspace,
        permissions: settings.permissions,
        writableDirs: settings.writableDirs,
        sandboxReprompt: settings.sandboxReprompt ?? true,
        dataDir: config.dataDir,
        project: project,
        saveArtifact: (path, entryFile, {artifactId}) async {
          final resolved = resolvePath(path);
          if (artifactId != null) {
            await store.updateArtifact(chatId, artifactId, resolved, entryFile,
                project: project);
            return artifactId;
          }
          return store.createArtifact(chatId, resolved, entryFile, project: project);
        },
        generateImage:
            _imageGenerator(settings.imageProvider, settings.imageModel,
                settings.imageQuality),
        saveResource: (filename, bytes) =>
            store.saveResource(chatId, filename, bytes),
        registerTrigger: triggerRegistry?.call(chatId, project),
        editSettings: editSettings,
        packageSkill: (path, name) async {
          final resolved = resolvePath(path);
          final pkg = await packageSkillDirectory(config.fs, resolved, name);
          final bytes = packageSkillBytes(pkg);
          final installId = const Uuid().v4();
          final stagingDir = config.skillStagingDir(chatId, installId, project: project);
          await config.fs.directory(stagingDir).create(recursive: true);
          await config.fs
              .file(config.fs.path.join(stagingDir, "package.skill"))
              .writeAsBytes(bytes);
          return (installId: installId, name: pkg.name);
        },
        onShellOutput: (callId, text) =>
            controller.add(ShellOutputEvent(callId: callId, text: text)),
        onUsage: (usage) {
          _usage[chatId] = usage.contextTokens;
          _windows[chatId] = target.info?.context;
        },
      );
      // The real kill replaces the placeholder.
      _running.replace(stopKey, agent.cancel);

      // A resumed turn has no prompt of its own to read `@agent` mentions out
      // of, so they come off the message that started it. A member turn is
      // the other shape: the overlay is the member's prompt from the library
      // as it stands now, and it replaces the mentions rather than joining
      // them.
      final said =
          prompt ?? history.lastWhereOrNull((m) => m.role == MessageRole.user);
      final memberBody = settings.omadaMember == null
          ? null
          : memberPrompt(libraryFor(settings.project), settings.omadaMember!);
      final mentions = agentPromptFrom(said?.documents ?? const {});
      final agentPrompt = memberBody ?? mentions;
      final events = prompt == null
          ? agent.resume(agentPrompt: agentPrompt)
          : agent.run(prompt,
              agentPrompt: agentPrompt,
              mayDress: mayDress(session, history, settings.omadaMember));

      var reply = "";
      var endedDone = false;
      await for (final event in events) {
        if (controller.isClosed) break;
        if (event is TextDelta) reply += event.text;
        if (event is DoneEvent && !event.aborted) {
          // A stopped turn ends aborted, said on the way out.
          if (_stopping.contains(controller)) continue;
          endedDone = true;
        }
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
      final writer = endedDone && settings.memory.extract
          ? _resolveModel(settings.memory.bgModel, settings.memory.bgProvider,
              defaultOf: LlmProviderConfig.lightDefaultOf)
          : null;
      if (memoryStore != null && writer != null) {
        // Unwatched on purpose: the turn is over, and the background memory
        // work must neither slow anything down nor be able to fail. The
        // consolidation rides behind the extraction rather than beside it —
        // the two would race over the store, and the call order is the
        // script's in a test.
        unawaited(_extractMemories(
          target: writer,
          store: memoryStore,
          chatId: chatId,
          prompt: prompt,
          history: history,
          reply: reply,
        ).then((_) => _consolidateMemories(
            target: writer, store: memoryStore, chatId: chatId)));
      }
    } catch (e) {
      _fail(controller, "$e");
    } finally {
      _clearApprovals(chatId);
      _clearQuestions(chatId);
      if (_stopping.remove(controller) && !controller.isClosed) {
        controller.add(const DoneEvent(aborted: true));
      }
      if (!controller.isClosed) await controller.close();
      _drained.remove(controller)?.complete();
      final open = _controllers[chatId];
      if (open != null && open.remove(controller) && open.isEmpty) {
        _controllers.remove(chatId);
      }
      // Last, after the stream is closed: dropping it here is what releases
      // Android's hold on the process, and the listener is still writing the
      // turn's closing records when the agent itself has stopped.
      _running.removeKey(stopKey);
    }
  }

  /// Where a turn in [project] reaches for the project's files, and the
  /// `HOME` of its commands where the driver takes one: the shared workspace
  /// where it is shared, the chat's own otherwise, so that nothing reaches
  /// past the conversation.
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
    StreamController<AgentEvent> controller,
    String stopKey, {
    required List<Message> history,
    required String? project,
    required bool sharedWorkspace,
    Map<String, String> environment = const {},
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
        timeout: options.commandTimeout,
        environment: environment,
        project: project);
    // Before the wait, so Stop kills the command rather than only closing the
    // stream over it.
    _running.replace(stopKey, run.kill);
    controller.add(StatusEvent(runningTool(bashToolName)));
    _reportOutput(controller, run);

    // The session does not feed the command and the command does not feed it:
    // a chat reopened after a restart fills its session from the log, and that
    // reading runs while the command takes its time rather than ahead of it.
    final filling = _sessionOf(chatId, history);
    final result = await run.result;
    final session = await filling;
    // Stopped past the grace: the turn ended without its part, so the session
    // must not hold one either.
    if (controller.isClosed) return;
    // The directory the shell was left in rides on the part as a fact; the
    // projection words the change, the way it does for the model's commands.
    final part = ShellRunPart(
      command: command,
      returnCode: result.returnCode,
      output: result.output,
      exceptionInfo: result.exceptionInfo,
      cwd: result.cwd,
      violations: result.violations,
    );
    controller.add(ShellRunEvent(part));
    if (!_stopping.contains(controller)) controller.add(const DoneEvent());
    // The same two functions a turn with a model in it uses, over the same one
    // part that was just reported: the prompt through `projectionOf`, the reply
    // through `assistantMessages`. The `!` turn writes its own reply, and that
    // is the only way it differs. The dress is the room's fact, read like
    // every dispatch's — see [mayDress].
    final dress = mayDress(session, history, null);
    session.messages
      ..addAll(await projectionOf([prompt],
          first: dress, load: _resourcesOf(chatId)))
      ..addAll(assistantMessages([part]));
  }

  /// Whether the turn this dispatch opens may dress its prompt as the task:
  /// the viewer's first own mail, which is what a whole-span walk of
  /// [history] would decide (one message at a call site, decided here).
  /// Only a user message is mail — the projection words replies by their
  /// author, never through the dresser. An empty history on a warm session
  /// is the caller saying nothing about the room, and not this predicate's
  /// call — the held words stand.
  bool mayDress(BuiltinSession session, List<Message> history, String? viewer) =>
      (session.isFresh || history.isNotEmpty) &&
      !history
          .where((m) => m.role == MessageRole.user)
          .any((m) => addressedTo(m, viewer));

  /// The chat's session, worded for [viewer] — null the house — and filled
  /// from [history] where a fill is due: a participant's first turn fills
  /// whole, worded for them, and a resume rebuilds whether or not the
  /// session is held. **A warm session runs `_syncSession` first** — the
  /// room's history worded onto it, appended where the log has gained since
  /// the covered ids. See that method for the one rule it is.
  ///
  /// [compactions] ride with [history] the way it rides with the prompt: the
  /// projection reads only the markers whose boundary the history holds, so a
  /// fragment projects the span it names and the summary lands where the log
  /// put it.
  Future<BuiltinSession> _sessionOf(String chatId, List<Message> history,
      {bool rebuild = false,
      String? viewer,
      List<ConversationCompaction> compactions = const []}) async {
    final key = _memberKey(chatId, viewer);
    final session = _sessions.putIfAbsent(key, BuiltinSession.new);
    if (rebuild || session.isFresh) {
      session.replaceWith(await projectionOf(history,
          load: _resourcesOf(chatId), viewer: viewer, compactions: compactions));
      session.coveredBy(history);
      return session;
    }
    await _syncSession(session, chatId, history, viewer: viewer);
    return session;
  }

  /// The warm session behind [history] — which is the thread as the room
  /// holds it now, ending before the prompt this dispatch is sending. The
  /// session is a cache the log is the truth of; in a room other
  /// participants write while this one is idle, and **this one rule is how
  /// every participant catches up**: the span the log gained since the
  /// session's covered prefix is worded onto the covered end, one wording per
  /// message — which is one a projection of a whole span also builds, the cwd
  /// note included — with the messages already held (say the last turn's own
  /// prompt and reply, the live tail) confirmed against the log's wordings
  /// and covered, so nothing is worded and nothing re-encodes twice, and the
  /// warm prefix stays a prefix.
  ///
  /// What the log no longer explains is re-worded **from the log itself** —
  /// the store's records, replayed — never from the caller's history, whose
  /// stale copy is exactly what a held session's own words are there to win
  /// over: a rewind the explicit reset missed, a tail richer than the log (a
  /// checkpoint that failed, an aborted turn's last second). The wording
  /// failures a divergence can have are the store's; a session left behind
  /// here is re-synced at the next dispatch over whatever the log says then.
  Future<void> _syncSession(
    BuiltinSession session,
    String chatId,
    List<Message> history, {
    required String? viewer,
  }) async {
    // No history is the caller saying nothing about the room — the held
    // words stand, whatever they are. The room's own dispatches always pass
    // the thread; the shortcut belongs to the fills.
    if (history.isEmpty) return;
    final covered = session.covered;
    // The covered ids are the history's head, or the session is beyond what
    // the caller words a room with and the log says it again.
    for (var i = 0; i < covered.length; i++) {
      if (i >= history.length || history[i].id != covered[i]) {
        return _refillFromLog(session, chatId, viewer: viewer);
      }
    }
    final gained = history.sublist(covered.length);
    if (gained.isEmpty) return;

    // The dress, per message, is a fact of the room: the viewer's first own
    // mail dresses and nothing after it does. [ownBefore] is whether the
    // covered span has had theirs; it carries through the walk.
    var ownBefore = history.take(covered.length).any((m) => addressedTo(m, viewer));

    final tail = session.tail;
    // The live tail beyond the covered prefix is the last turns' own wording,
    // which the log now explains: each gained message is worded and confirmed
    // against the tail's next slice until the tail runs out, and the rest
    // words as one span — which batches the attachments' reads. The first
    // message whose wording disagrees inside the tail sends the whole thing
    // to the log; one partial append is overwritten by the refill's own.
    var confirmed = 0;
    final confirmedIds = <String>[];
    final fresh = <Message>[];
    for (final (index, message) in gained.indexed) {
      if (confirmed < tail.length) {
        final mine = addressedTo(message, viewer);
        final entries = await projectionOf([message],
            first: mine && !ownBefore,
            viewer: viewer,
            load: _resourcesOf(chatId));
        if (_sameSlice(tail, confirmed, entries)) {
          confirmed += entries.length;
          confirmedIds.add(message.id);
          ownBefore = ownBefore || mine;
          continue;
        }
        return _refillFromLog(session, chatId, viewer: viewer);
      }
      // Past the tail: the whole span from here words as it stands, first
      // own-mail inside and all.
      fresh.addAll(gained.sublist(index));
      break;
    }
    if (fresh.isNotEmpty) {
      final wordings = await projectionOf(fresh,
          first: !ownBefore, viewer: viewer, load: _resourcesOf(chatId));
      session.messages.addAll(wordings);
      confirmedIds.addAll([for (final message in fresh) message.id]);
      confirmed += wordings.length;
    }
    session.advance(confirmed, confirmedIds);
  }

  /// Fill [session] whole from the log, the room's one source of truth. A
  /// log that says nothing leaves the session as it stands — the held words
  /// are all the truth there is, and a divergence with nothing to resolve
  /// against is left alone.
  Future<void> _refillFromLog(
      BuiltinSession session, String chatId,
      {required String? viewer}) async {
    final replayed = replayTree(await store.readRecords(chatId));
    if (replayed.messages.isEmpty) return;
    session.replaceWith(await projectionOf(replayed.messages,
        load: _resourcesOf(chatId),
        viewer: viewer,
        compactions: replayed.compactions));
    session.coveredBy(replayed.messages);
  }

  /// Byte-for-byte the same conversation entry — what parity says a live
  /// accumulation and a projection of the same records are. By field, and by
  /// the value classes' own [LlmToolCall]/[LlmAttachment] equality: two
  /// independently built wordings of the same records have to compare equal
  /// or the sync's confirm would refuse every entry that carries a call.
  static bool _sameWording(LlmMessage a, LlmMessage b) =>
      a.role == b.role &&
      a.text == b.text &&
      a.reasoning == b.reasoning &&
      a.reasoningSignature == b.reasoningSignature &&
      a.toolCallId == b.toolCallId &&
      const ListEquality<LlmToolCall>().equals(a.toolCalls, b.toolCalls) &&
      const ListEquality<LlmAttachment>().equals(a.attachments, b.attachments);

  /// Whether [entries] word exactly what [tail] holds from [at] on.
  static bool _sameSlice(List<LlmMessage> tail, int at, List<LlmMessage> entries) {
    if (at + entries.length > tail.length) return false;
    for (var i = 0; i < entries.length; i++) {
      if (!_sameWording(tail[at + i], entries[i])) return false;
    }
    return true;
  }

  /// The user's own `!` command, watched through the agent's one watch shape —
  /// no call id, there being nothing called a tool.
  void _reportOutput(StreamController<AgentEvent> controller, ShellRun run) =>
      BuiltinAgent.watchShellOutput(run, (text) {
        if (!controller.isClosed) {
          controller.add(ShellOutputEvent(callId: null, text: text));
        }
      });

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
      {required String? model, required String? provider}) async {
    final target = _resolveModel(
      model,
      provider,
      defaultOf: LlmProviderConfig.lightDefaultOf,
      title: true,
    );
    if (target == null) return null;
    try {
      final answer = await _oneCompletion(
          target, [LlmMessage(role: LlmRole.user, text: prompt)],
          timeout: const Duration(seconds: 60));
      return answer == null || answer.isEmpty ? null : answer;
    } catch (_) {
      return null;
    }
  }

  /// The summarizer: the conversation as any turn would read it, one ask, one
  /// reply. Unlike [ask] this runs on the chat's own model — the summary is
  /// only as good as the context it had, and the light default was not the one
  /// that saw the work. The window is minutes rather than [ask]'s sixty
  /// seconds: a long conversation is a long read.
  ///
  /// [summaryFrom] cuts the tags, so what this hands back is the text the
  /// marker carries. Null with a log line, like every background failure —
  /// there is no turn to report it on.
  @override
  Future<ConversationCompaction?> compact(
    String chatId, {
    required List<Message> history,
    required List<ConversationCompaction> compactions,
    required TurnSettings settings,
    required String? instructions,
  }) async {
    if (_running.any(chatId)) return null;
    final target = _resolveModel(settings.model, settings.provider);
    if (target == null) return null;
    if (history.isEmpty) return null;
    // The ask has to fit the window with room for the summary it produces; a
    // budget that would fill the whole window is how the last attempt got
    // here in the first place. The window is the model's own where the
    // registry knows it, the settings' global guess where it does not — and
    // where the model still refuses a span, the ladder below is the answer.
    final window = target.info?.context ??
        AppSettings.load(config).totalContext;
    final budget = window ~/ 2;
    // The retry ladder: a span too big to summarize is not a failure to give
    // up on but a span to summarize less of. Each attempt drops the oldest
    // half of what it was asked to read, so a conversation that will not fit
    // whole still leaves a summary of its newest half — and a marker that
    // covers only what was read.
    //
    // The loader is memoised across the attempts, which is the point of the
    // ladder: the surviving half's attachments were just read, and a span
    // that will not fit is the expected case for the chats this runs on —
    // one read per resource, not one per attempt.
    final read = <String, Future<Uint8List?>>{};
    Future<Uint8List?> loader(String resource) =>
        read.putIfAbsent(resource, () => _resourcesOf(chatId)(resource));
    List<Message> span = history;
    List<Message> halve() => span.sublist((span.length / 2).ceil());
    // Loop-invariant: the markers do not change across the ladder.
    final priorSummary = compactions.lastOrNull?.summary;
    for (var attempt = 0; attempt < 3; attempt++) {
      final projected = await projectionOf(span,
          load: loader, compactions: compactions);
      if (projected.isEmpty) return null;
      final cut = CompactPrompt.build(
        conversation: projected,
        instructions: instructions,
        priorSummary: priorSummary,
      );
      // Where the ask itself would not fit, dropping the oldest half is the
      // only answer; where it would, the span stands.
      if (estimateTokens(cut) > budget) {
        span = halve();
        continue;
      }
      try {
        final reply = await _oneCompletion(target, cut,
            timeout: const Duration(minutes: 3));
        final summary = reply == null ? null : CompactPrompt.summaryFrom(reply);
        if (summary != null) {
          final marker = ConversationCompaction(
              upToMessageId: span.last.id, summary: summary);
          final after = await projectionOf(history,
              load: loader, compactions: [...compactions, marker]);
          return marker.copyWith(chatTokens: estimateTokens(after));
        }
        logFailure("compact", "empty summary for $chatId");
      } catch (e) {
        logFailure("compact", "summarizer failed for $chatId", e);
      }
      // A reply that said nothing, or an error: halve and try once more, the
      // same ladder the too-big ask takes.
      span = halve();
    }
    return null;
  }

  /// What a turn that ended cleanly leaves behind: a background model reads
  /// the exchange and keeps the facts that outlive it. Runs unwatched, so it
  /// fails by writing nothing and leaving a line in the log — a turn is over
  /// when its last event is out, whatever this is still doing.
  Future<void> _extractMemories({
    required _Target target,
    required MemoryStore store,
    required String chatId,
    required Message? prompt,
    required List<Message> history,
    required String reply,
  }) async {
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
      final answer = await _oneCompletion(target,
          [LlmMessage(role: LlmRole.user, text: question)],
          timeout: const Duration(seconds: 60)) ?? "";
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
    required _Target target,
    required MemoryStore store,
    required String chatId,
  }) async {
    if (_consolidating) return;
    _consolidating = true;
    try {
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
      final answer = await _oneCompletion(
            target, [LlmMessage(role: LlmRole.user, text: question)],
            timeout: const Duration(seconds: 60)) ?? "";
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

  /// The one-shot read, in the three shapes that ask it: the last completion
  /// the model streams within the window, trimmed, and null where it streamed
  /// nothing. The three call sites differ only in the timeout and in what an
  /// empty answer means to them; the window keeps a stuck provider from
  /// holding the call forever, and the timeout is on the stream rather than
  /// the future it collects, a timed-out future leaving the response being
  /// read to nobody.
  Future<String?> _oneCompletion(
    _Target target,
    List<LlmMessage> messages, {
    required Duration timeout,
  }) async {
    final chunks = await target.client
        .stream(messages, model: target.modelId)
        .timeout(timeout)
        .toList();
    return chunks.whereType<LlmCompletion>().lastOrNull?.message.text.trim();
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
        final key = entry.key;
        final text = entry.value is String ? _fact(entry.value as String) : null;
        if (key is! String || text == null) continue;
        replaces[key] = text;
      }
    }
    final memories = decoded["memories"] ?? decoded["add"];
    return (
      add: memories is List ? _factsFrom(memories) : const [],
      replaces: replaces,
      delete: [
        if (decoded["delete"] case final List delete)
          for (final entry in delete)
            if (entry is String) entry,
      ],
    );
  }

  /// One fact as the store takes it: trimmed and cut to the write cap, or
  /// nothing where there is no fact at all.
  String? _fact(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    return text.length > recallEntryChars
        ? text.substring(0, recallEntryChars)
        : text;
  }

  /// The new-fact half of the answer, at most five of them, the way the old
  /// shape was.
  List<String> _factsFrom(Object? value) {
    final facts = <String>[];
    for (final entry in (value as List)) {
      final text = entry is String ? _fact(entry) : null;
      if (text == null) continue;
      facts.add(text);
      if (facts.length == 5) break;
    }
    return facts;
  }

  /// The config is read once and reused: going back through the registry by id
  /// would re-read and re-parse `settings.json` for each question asked of it.
  ///
  /// [defaultOf] says which provider field a null model resolves to — the chat
  /// default for a turn, the light one for the title, memory and classifier
  /// roles. None is None: a provider without that field leaves nothing to
  /// answer with, which is the caller's error, not a guess from a model list.
  ///
  /// [title] is the title's ask, the one role a title-only model answers
  /// ([isTitleOnlyModel]); everything else resolves one to nothing, so a
  /// setting written before the gate leaves its feature off rather than
  /// compacting on every turn.
  _Target? _resolveModel(
    String? model,
    String? provider, {
    String? Function(LlmProviderConfig) defaultOf = LlmProviderConfig.chatDefaultOf,
    bool title = false,
  }) {
    if (provider == null) return null;
    final endpoint = registry.endpointFor(provider);
    if (endpoint == null) return null;
    final config = endpoint.config;
    final modelId = model ?? defaultOf(config);
    if (modelId == null || modelId.isEmpty) return null;
    if (!title && isTitleOnlyModel(provider, modelId)) return null;
    final client = registry.clientOf(endpoint);
    final info = modelInfoOf(config, modelId);
    // Here rather than at each request: everything that asks the model
    // resolves it through this, the compaction's one-shot read included.
    // Unknown passes images through: a model only the endpoint lists is
    // trusted as it was before there was a catalog to ask.
    return (
      client: info?.readsImages ?? true ? client : TextOnlyClient(client),
      modelId: modelId,
      info: info,
    );
  }

  /// The classifier model, resolved the same way the main model is. Null when
  /// no classifier provider is named — auto mode falls back to asking. A
  /// provider named without a model resolves to its light default.
  PermissionClassifier? _resolveClassifier(String? provider, String? model) {
    final target = _resolveModel(
      model,
      provider,
      defaultOf: LlmProviderConfig.lightDefaultOf,
    );
    if (target == null) return null;
    return LlmClassifier(client: target.client, model: target.modelId);
  }

  /// Null, and so no tool, where the image model is off or its provider does
  /// not speak the OpenAI shape: Anthropic makes no images.
  Future<List<LlmAttachment>> Function(String prompt)? _imageGenerator(
      String? provider, String? model, ImageQuality quality) {
    final endpoint = provider == null ? null : registry.endpointFor(provider);
    if (endpoint == null) return null;
    final modelId = model ?? LlmProviderConfig.imageDefaultOf(endpoint.config);
    final client = registry.clientOf(endpoint);
    if (modelId == null || client is! OpenAiClient) return null;
    return (prompt) => client.generateImage(prompt,
        model: modelId,
        quality: quality == ImageQuality.auto ? null : quality.name);
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
    // The "always" answers reach the agent whole: it derives the standing rule
    // from the approval it holds and grants it for the rest of the turn.
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

  static const _stopGrace = Duration(seconds: 2);

  @override
  Future<void> abort(String chatId) async {
    final open = Set.of(_controllers[chatId] ?? const <StreamController<AgentEvent>>{});
    _stopping.addAll(open);
    // Every turn the chat has in flight, not the last one registered.
    await _running.stopAll(chatId);
    _clearApprovals(chatId);
    _clearQuestions(chatId);
    // A killed command's result, and what it printed, arrives after the kill:
    // each turn gets a grace to forward it rather than being closed over it.
    await Future.wait([
      for (final controller in open)
        if (_drained[controller] case final drained?) drained.future,
    ]).timeout(_stopGrace, onTimeout: () => const []);
    // Only the turns this stop was for: one sent during the grace is not.
    final still = _controllers[chatId];
    still?.removeAll(open);
    if (still != null && still.isEmpty) _controllers.remove(chatId);
    for (final controller in open) {
      _stopping.remove(controller);
      if (controller.isClosed) continue;
      controller.add(const DoneEvent(aborted: true));
      await controller.close();
    }
  }

  @override
  Future<void> resetSession(String chatId,
      {List<Message> history = const [],
      List<ConversationCompaction> compactions = const []}) async {
    await _running.stopAll(chatId);
    final house = _sessions.putIfAbsent(chatId, BuiltinSession.new);
    house.replaceWith(await projectionOf(history,
        load: _resourcesOf(chatId), compactions: compactions));
    house.coveredBy(history);
    // The room's other participants read on their own dispatches, which the
    // sync fills from wherever the log now is: a session worded for them
    // before the rewind holds a conversation the log no longer describes.
    _forgetMemberSessions(chatId);
  }

  /// What a member's session is keyed by: the chat, and the bare member name
  /// the room's schedule keys by — the house's own is the chat id bare.
  String _memberKey(String chatId, String? viewer) =>
      viewer == null ? chatId : "$chatId\u0000$viewer";

  /// Forget every session a room worded for a member, and no other chat's:
  /// a rewind or a delete takes their projections with it, the next
  /// dispatch re-filling from the thread whatever it then holds.
  void _forgetMemberSessions(String chatId) =>
      _sessions.removeWhere((key, _) => key.startsWith("$chatId\u0000"));

  @override
  Future<void> disposeChat(String chatId) async {
    // Before the store forgets it: which project the chat's shell stood in.
    final project = await store.projectOf(chatId);
    shell.closeSession(config.workspaceDir(chatId, project: project));
    await abort(chatId);
    _sessions.remove(chatId);
    _usage.remove(chatId);
    _windows.remove(chatId);
    _forgetMemberSessions(chatId);
  }

  @override
  int? usageFor(String chatId) => _usage[chatId];

  @override
  int? contextWindowFor(String chatId) => _windows[chatId];

  @override
  void closeChatShell(String chatId, {required String? project}) =>
      shell.closeSession(config.workspaceDir(chatId, project: project));

  /// Concurrently: this runs on the way out, and the app would otherwise wait
  /// out every live turn's process kill one after another.
  @override
  Future<void> shutdown() async {
    await Future.wait(_running.value.toList().map(abort));
    _sessions.clear();
    registry.close();
    webSearch.close();
    await browser.close();
    await _memoryNotes.close();
    await subAgents.close();
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
  /// nothing here has to tell them apart. Keyed by chat **and a token**, not
  /// the chat alone — a parallel round runs several turns of one chat at
  /// once, and a second registration must not drop the first's kill.
  final Map<String, Future<void> Function()> _stops = {};

  var _token = 0;

  /// Registers a stop for [chatId], returning the key the turn's own cleanup
  /// removes.
  String add(String chatId, Future<void> Function() stop) {
    final key = "$chatId\u0000${_token++}";
    _stops[key] = stop;
    value = chats;
    return key;
  }

  /// Swaps what [key] stops, without a second publish.
  void replace(String key, Future<void> Function() stop) {
    _stops[key] = stop;
  }

  /// The turn [key] registered finished on its own; the chat keeps any
  /// sibling still running. Publishes only where something was actually
  /// removed — a `Set` compares by identity, so a fresh one would notify
  /// every time and cost a round trip to the platform.
  void removeKey(String key) {
    if (_stops.remove(key) != null) value = chats;
  }

  /// The chats with a turn in flight — what [runningTurns] publishes.
  Set<String> get chats =>
      {for (final key in _stops.keys) key.substring(0, key.indexOf("\u0000"))};

  /// Whether [chatId] holds a turn in flight — the guard a background call
  /// checks before it runs, since the session it would summarize is being
  /// rewritten underneath it while one does. Keys rather than the set: the
  /// answer is one `startsWith`, no materialized copy of the chats.
  bool any(String chatId) =>
      _stops.keys.any((k) => k.startsWith("$chatId\u0000"));

  /// Kills every stop [chatId] holds, in the order they were registered.
  Future<void> stopAll(String chatId) async {
    final keys = [
      for (final key in _stops.keys)
        if (key.startsWith("$chatId\u0000")) key
    ];
    for (final key in keys) {
      await _stops.remove(key)?.call();
    }
    if (keys.isNotEmpty) value = chats;
  }
}

/// A model resolved to ask: the client, the id, and what the catalog knows.
typedef _Target = ({LlmClient client, String modelId, ModelInfo? info});
