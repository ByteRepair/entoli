import "dart:async";

import "package:flutter/foundation.dart";
import "package:uuid/uuid.dart";

import "../../core/config.dart";
import "../../domain/agent_backend.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "../../domain/shell.dart";
import "llm/llm_client.dart";
import "llm/llm_registry.dart";
import "miniswe_agent.dart";

/// mini-swe-agent, running in this process. The loop is [MinisweAgent]; this
/// is what agent-chat talks to: it holds a session per chat, resolves which
/// endpoint a turn runs against, and turns the composer's `/` and `@` syntax
/// into a task and a system prompt before the agent ever sees it.
class MinisweBackend implements AgentBackend {
  MinisweBackend({
    required this.config,
    required this.registry,
    required this.shell,
    this.library,
    this.options = const MinisweOptions(),
  });

  final AppConfig config;
  final LlmRegistry registry;
  final Shell shell;

  /// agent-chat's own commands and agents, expanded into the task and the
  /// system prompt before the agent sees them.
  final PromptLibrary? library;

  /// Limits and timeouts for every turn.
  final MinisweOptions options;

  final Map<String, MinisweSession> _sessions = {};
  final Map<String, MinisweAgent> _running = {};
  final Map<String, StreamController<AgentEvent>> _controllers = {};
  final Map<String, List<ToolApproval>> _approvals = {};
  /// One per approval on screen, created when the request is forwarded and
  /// completed by whichever comes first: the user's answer, or the turn ending.
  final Map<String, Completer<ApprovalResponse>> _pending = {};

  /// A message that is nothing but `/name` plus arguments runs that command.
  /// The name may not hold a slash, so `/usr/bin/foo is broken` stays prose.
  /// Matches what `activeCompletionToken` offers in the composer's menu —
  /// anything it can offer has to dispatch here.
  static final _command = RegExp(r"^/([^\s/]+)(?:\s+([\s\S]*))?$");

  /// `@name` addresses an agent, but only where a word starts, so an email
  /// address is not a mention.
  static final _mention = RegExp(r"(?<=^|\s)@([\w.-]+)");

  @override
  Future<Chat> createChat({String? title}) async {
    final chatId = const Uuid().v4();
    config.ensureChatDirs(chatId);
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
    String? model,
    String? provider,
    bool approveCommands = true,
  }) {
    final controller = StreamController<AgentEvent>();
    _controllers[chatId] = controller;
    // Returned rather than yielded, so the caller is listening before the turn
    // starts. Closing a controller nobody listens to never completes.
    unawaited(_runTurn(chatId, text, controller,
        model: model,
        provider: provider,
        attachments: attachments,
        approveCommands: approveCommands));
    return controller.stream;
  }

  Future<void> _runTurn(
    String chatId,
    String text,
    StreamController<AgentEvent> controller, {
    String? model,
    String? provider,
    List<Attachment> attachments = const [],
    bool approveCommands = true,
  }) async {
    try {
      final target = _resolveModel(model, provider);
      if (target == null) {
        _fail(
            controller,
            provider == null
                ? "No model is selected. Add a provider in Settings and pick one."
                : "'$provider' is not configured. Add it in Settings, or pick another model.");
        return;
      }

      config.ensureChatDirs(chatId);
      final agent = MinisweAgent(
        session: _sessions.putIfAbsent(chatId, MinisweSession.new),
        client: target.client,
        shell: shell,
        workspace: config.workspaceDir(chatId).path,
        model: target.modelId,
        options: options,
        requireApproval: approveCommands,
        approve: _awaitApproval,
      );
      _running[chatId] = agent;

      await for (final event in agent.run(
        _taskOf(text),
        attachments: attachments.map(_toLlmAttachment).toList(),
        agentPrompt: _agentPromptOf(text),
      )) {
        if (controller.isClosed) break;
        if (event is ApprovalRequestEvent) {
          _approvals.putIfAbsent(chatId, () => []).add(event.approval);
          // Created here rather than where it is awaited: the banner is on
          // screen the moment this is forwarded, so the answer can beat the
          // agent to asking.
          _pending.putIfAbsent(event.approval.id, Completer.new);
        }
        controller.add(event);
      }
    } catch (e) {
      _fail(controller, "$e");
    } finally {
      _running.remove(chatId);
      _clearApprovals(chatId);
      if (!controller.isClosed) await controller.close();
    }
  }

  void _fail(StreamController<AgentEvent> controller, String message) {
    if (controller.isClosed) return;
    controller.add(ErrorEvent(message));
    controller.add(const DoneEvent());
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

  LlmAttachment _toLlmAttachment(Attachment attachment) => LlmAttachment(
        filename: attachment.filename,
        mimeType: attachment.mimeType,
        bytes: attachment.bytes,
      );

  Future<ApprovalResponse> _awaitApproval(ToolApproval approval) =>
      _pending.putIfAbsent(approval.id, Completer.new).future;

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

  /// What is on screen for [chatId]. Not on `AgentBackend` — the UI tracks
  /// approvals from the event stream; this is for tests of this class.
  ///
  /// A copy: answering one removes it, and a caller that walks the list while
  /// answering each would be mutating what it is reading.
  @visibleForTesting
  Future<List<ToolApproval>> pendingApprovals(String chatId) async =>
      List.unmodifiable(_approvals[chatId] ?? const []);

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

  /// Every failure here is reported as it happens, so silence only ever means
  /// work: a command still running, or a model still thinking. The budget is
  /// therefore the longest a command may take plus room for the call that
  /// follows it.
  @override
  Duration get stallTimeout => options.commandTimeout + const Duration(seconds: 60);

  @override
  Future<void> abort(String chatId) async {
    await _running.remove(chatId)?.cancel();
    _clearApprovals(chatId);
    final controller = _controllers.remove(chatId);
    if (controller != null && !controller.isClosed) {
      controller.add(const DoneEvent());
      await controller.close();
    }
  }

  @override
  Future<void> resetSession(String chatId, {List<Message> history = const []}) async {
    await _running.remove(chatId)?.cancel();
    _sessions.putIfAbsent(chatId, MinisweSession.new).seed(transcriptOf(history));
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
    await Future.wait(_running.keys.toList().map(abort));
    _sessions.clear();
    registry.close();
  }

  @override
  Future<List<ModelOption>> models() => registry.models();
}
