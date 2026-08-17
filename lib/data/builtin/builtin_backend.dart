import "dart:async";

import "package:collection/collection.dart";
import "package:flutter/foundation.dart";
import "package:uuid/uuid.dart";

import "../../core/config.dart";
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
import "llm/gated_client.dart";
import "llm/llm_client.dart";
import "llm/llm_registry.dart";
import "llm/rate_limit_gate.dart";
import "permission_classifier.dart";
import "projection.dart";
import "sub_agent.dart";
import "task_tool.dart";

/// The built-in agent, running in this process. The loop is [BuiltinAgent];
/// this is what Entoli talks to: it holds a session per chat, resolves which
/// endpoint a turn runs against, and turns the composer's `/` and `@` syntax
/// into a task and a system prompt before the agent ever sees it.
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

  /// Entoli's own commands and agents, expanded into the task and the
  /// system prompt before the agent sees them.
  final PromptLibrary? library;

  /// Web search and fetch, chosen by the platform like [shell] is:
  /// `DuckDuckGoSearch` on desktop and Android, `UnavailableWebSearch` in a
  /// browser. Named rather than defaulted because a default of the first would
  /// ship its HTML parser to every browser that loads the app and could never
  /// call it.
  final WebSearch webSearch;

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

  /// A message that is nothing but `/name` plus arguments runs that command.
  /// The name may not hold a slash, so `/usr/bin/foo is broken` stays prose.
  /// Matches what `activeCompletionToken` offers in the composer's menu —
  /// anything it can offer has to dispatch here.
  static final _command = RegExp(r"^/([^\s/]+)(?:\s+([\s\S]*))?$");

  /// `@name` addresses an agent, but only where a word starts, so an email
  /// address is not a mention.
  static final _mention = RegExp(r"(?<=^|\s)@([\w.-]+)");

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
    String text, {
    List<Attachment> attachments = const [],
    List<Message> history = const [],
    TurnSettings settings = const TurnSettings(),
  }) =>
      _start(chatId, text,
          attachments: attachments, history: history, settings: settings);

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
    String? text, {
    List<Attachment> attachments = const [],
    List<Message> history = const [],
    required TurnSettings settings,
  }) {
    final controller = StreamController<AgentEvent>();
    _controllers[chatId] = controller;
    unawaited(_runTurn(chatId, text, controller,
        attachments: attachments, history: history, settings: settings));
    return controller.stream;
  }

  /// [text] is what the user said, or null to carry on the turn [history] ends
  /// in. Everything either needs — the model, the directories, the gate, the
  /// sub-agent runner — is the same; they differ only in what the agent is
  /// asked and in how much of the session is rebuilt first.
  Future<void> _runTurn(
    String chatId,
    String? text,
    StreamController<AgentEvent> controller, {
    List<Attachment> attachments = const [],
    List<Message> history = const [],
    required TurnSettings settings,
  }) async {
    final project = settings.project;
    try {
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
      final projectWorkspace = config.projectWorkspaceDir(project: project);
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
      );
      final classifier =
          _resolveClassifier(settings.classifierProvider, settings.classifierModel);
      final session = _sessions.putIfAbsent(chatId, BuiltinSession.new);
      // A session the app was not already holding is the one after a restart,
      // and it is empty. Filling it from the conversation is what keeps the
      // chat going rather than starting it over. A resume rebuilds it either
      // way, so that carrying on in the same process and carrying on after a
      // restart put the same thing in front of the model — a checkpoint that
      // failed is swallowed, so a live session can hold more than the log does.
      // Before the session is built, so the revived results are in the history
      // it is projected from rather than patched in afterwards.
      if (text == null) {
        history = await _reviveSubAgents(history, subAgentRunner, subAgentLog, controller);
      }
      if (text == null || session.isFresh) {
        session.replaceWith(projectionOf(history));
      }
      final agent = BuiltinAgent(
        session: session,
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
        saveArtifact: (path, {artifactId}) async {
          final resolved = resolveWorkspacePath(config.fs, path, workspace, projectWorkspace);
          if (artifactId != null) {
            await store.updateArtifact(chatId, artifactId, resolved, project: project);
            return artifactId;
          }
          return store.createArtifact(chatId, resolved, project: project);
        },
      );
      _running.add(chatId, agent);

      // A resumed turn has no prompt of its own to read `@agent` mentions out
      // of, so they come off the message that started it.
      final agentPrompt = _agentPromptOf(text ?? _lastUserText(history));
      final events = text == null
          ? agent.resume(agentPrompt: agentPrompt)
          : agent.run(
              _taskOf(text),
              attachments: attachments.map(_toLlmAttachment).toList(),
              agentPrompt: agentPrompt,
            );

      await for (final event in events) {
        if (controller.isClosed) break;
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

  /// The config is read once and reused: going back through the registry by id
  /// would re-read and re-parse `settings.json` for each question asked of it.
  ({LlmClient client, String modelId})? _resolveModel(String? model, String? provider) {
    if (provider == null) return null;
    final config = registry.configFor(provider);
    if (config == null) return null;
    // A provider with one model listed does not need it pinned as well; with
    // none, there is nothing to guess from.
    final modelId = model ?? config.models.firstOrNull;
    if (modelId == null || modelId.isEmpty) return null;
    return (client: registry.clientOf(config), modelId: modelId);
  }

  /// The classifier model, resolved the same way the main model is. Null when
  /// no classifier model is named — auto mode falls back to asking.
  PermissionClassifier? _resolveClassifier(String? provider, String? model) {
    if (provider == null || model == null) return null;
    final target = _resolveModel(model, provider);
    if (target == null) return null;
    return LlmClassifier(client: target.client, model: target.modelId);
  }

  /// `/name args` is the command's template with the arguments in it. A name
  /// the library does not know is left alone: it is more likely a path than a
  /// command nobody defined.
  String _taskOf(String text) {
    final match = _command.firstMatch(text.trim());
    if (match == null) return text;
    final document = library?.find(CompletionKind.command, match.group(1)!);
    if (document == null) return text;
    final arguments = match.group(2) ?? "";
    if (document.body.contains(r"$ARGUMENTS")) {
      return document.body.replaceAll(r"$ARGUMENTS", arguments);
    }
    return arguments.isEmpty ? document.body : "${document.body}\n\n$arguments";
  }

  /// `@name` puts that agent's prompt under the system message for this turn.
  /// Several mentions stack, in the order they were written.
  String? _agentPromptOf(String text) {
    final bodies = <String>[];
    for (final match in _mention.allMatches(text)) {
      final document = library?.find(CompletionKind.agent, match.group(1)!);
      if (document != null) bodies.add(document.body);
    }
    return bodies.isEmpty ? null : bodies.join("\n\n");
  }

  String _lastUserText(List<Message> history) =>
      history.lastWhereOrNull((m) => m.role == MessageRole.user)?.plainText ?? "";

  LlmAttachment _toLlmAttachment(Attachment attachment) => LlmAttachment(
        filename: attachment.filename,
        mimeType: attachment.mimeType,
        bytes: attachment.bytes,
      );

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
    await _running.remove(chatId)?.cancel();
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
    await _running.remove(chatId)?.cancel();
    _sessions.putIfAbsent(chatId, BuiltinSession.new).replaceWith(projectionOf(history));
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

  final Map<String, BuiltinAgent> _agents = {};

  void add(String chatId, BuiltinAgent agent) {
    _agents[chatId] = agent;
    value = _agents.keys.toSet();
  }

  /// Publishes only where something was actually removed: `abort` reaches chats
  /// with nothing running — deleting one does — and a `Set` compares by
  /// identity, so a fresh one would notify every time and cost a round trip to
  /// the platform to stop a service that was never started.
  BuiltinAgent? remove(String chatId) {
    final agent = _agents.remove(chatId);
    if (agent != null) value = _agents.keys.toSet();
    return agent;
  }
}
