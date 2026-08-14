// Desktop OpenCode backend: one `opencode serve` per chat, started lazily
// with the chat's workspace as working directory. All messages use
// POST /session/:id/prompt_async; events stream via SSE /event.
import "dart:async";
import "dart:convert";
import "dart:io";

import "package:uuid/uuid.dart";

import "../../core/config.dart";
import "../../core/platform/default_backend.dart";
import "../../domain/agent_backend.dart";
import "../../domain/models.dart";
import "opencode_models.dart";
import "opencode_transport.dart";

class OpencodeBackend implements AgentBackend {
  OpencodeBackend({required this.config, required this.transport});

  final AppConfig config;
  final OpencodeTransport transport;

  final Map<String, String> _chatToSession = {};
  final Map<String, StreamController<AgentEvent>> _controllers = {};
  final Map<String, StreamSubscription<OcEvent>> _eventSubs = {};
  final Map<String, List<ToolApproval>> _approvals = {};
  final Map<String, Set<String>> _seenTools = {};
  final Map<String, String> _pendingContext = {};

  @override
  BackendKind get kind => BackendKind.opencode;

  @override
  Future<Chat> createChat({String? title, String? model, String? provider}) async {
    final chatId = const Uuid().v4();
    config.workspaceDir(chatId);
    config.resourcesDir(chatId);
    final now = DateTime.now();
    return Chat(
      state: ChatState(
        id: chatId,
        title: title ?? "New chat",
        createdAt: now,
        updatedAt: now,
        backend: defaultBackendKind(),
        model: model,
        provider: provider,
      ),
      messages: const [],
    );
  }

  @override
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const [], String? model, String? provider}) {
    final controller = StreamController<AgentEvent>();
    _controllers[chatId] = controller;
    // Returned rather than yielded, so the caller is listening before the turn
    // starts. Closing a controller nobody listens to never completes.
    unawaited(_runTurn(chatId, text, controller, model: model, provider: provider));
    return controller.stream;
  }

  Future<void> _runTurn(
    String chatId,
    String text,
    StreamController<AgentEvent> controller, {
    String? model,
    String? provider,
  }) async {
    try {
      await transport.ensureServer(chatId, config.workspaceDir(chatId).path);

      var sessionId = _chatToSession[chatId];
      if (sessionId == null) {
        sessionId = await transport.createSession(chatId);
        _chatToSession[chatId] = sessionId;
        final seed = _pendingContext.remove(chatId);
        if (seed != null) await transport.injectContext(chatId, sessionId, seed);
      }

      // Attach before prompting, and hand each subscription its own
      // controller: a straggling event from the previous turn must not close
      // this one.
      await _eventSubs[chatId]?.cancel();
      final events = await transport.subscribe(chatId);
      _eventSubs[chatId] = events.listen(
        (event) => _handleEvent(event, chatId, controller),
        onError: (e) {
          if (!controller.isClosed) controller.add(ErrorEvent(e.toString()));
        },
        onDone: () {
          if (!controller.isClosed) {
            controller.add(const DoneEvent());
            controller.close();
          }
        },
      );

      await transport.promptAsync(chatId, sessionId, text: text, model: model, provider: provider);
    } catch (e) {
      if (!controller.isClosed) {
        controller.add(ErrorEvent(e.toString()));
        controller.add(const DoneEvent());
        await controller.close();
      }
    }
  }

  Future<void> _handleEvent(
    OcEvent event,
    String chatId,
    StreamController<AgentEvent> controller,
  ) async {
    if (controller.isClosed) return;

    final props = event.properties;
    final sessionId = props["sessionID"] as String?;
    if (sessionId != null && sessionId != _chatToSession[chatId]) return;

    switch (event.type) {
      case "message.part.delta":
        final delta = props["delta"] as String? ?? "";
        if (delta.isNotEmpty) controller.add(TextDelta(delta));

      case "message.part.updated":
        _handlePartUpdated(props, controller, chatId);

      case "session.status":
        final status = props["status"] as Map<String, dynamic>?;
        if (status?["type"] == "retry") {
          controller.add(RetryEvent(
            attempt: (status!["attempt"] as num?)?.toInt() ?? 1,
            message: status["message"] as String? ?? "",
          ));
        }

      case "permission.asked":
        final approval = ToolApproval(
          id: props["id"] as String? ?? "",
          toolName: (props["tool"] as Map<String, dynamic>?)?["name"] as String? ??
              props["permission"] as String? ??
              "unknown",
          argumentsJson: props["metadata"] == null ? null : jsonEncode(props["metadata"]),
        );
        _approvals.putIfAbsent(chatId, () => []).add(approval);
        controller.add(ApprovalRequestEvent(approval));

      case "permission.replied":
        final id = props["id"] as String?;
        _approvals[chatId]?.removeWhere((a) => a.id == id);

      case "session.error":
        final text = _errorText(props["error"]);
        if (text != null) controller.add(ErrorEvent(text));
        await _endTurn(chatId, controller);

      case "session.idle":
        await _endTurn(chatId, controller);

      case "session.next.text.delta":
        // Legacy event type — some versions still emit this.
        controller.add(TextDelta(props["delta"] as String? ?? ""));
    }
  }

  /// The turn is over: stop decoding events nobody is listening to. A new
  /// turn opens a fresh subscription.
  Future<void> _endTurn(String chatId, StreamController<AgentEvent> controller) async {
    controller.add(const DoneEvent());
    await controller.close();
    await _eventSubs.remove(chatId)?.cancel();
  }

  /// Every error variant opencode sends carries `name` plus `data.message`
  /// (APIError adds a status code). Aborts are user-initiated, so they are not
  /// worth reporting as failures.
  String? _errorText(Object? error) {
    if (error is! Map<String, dynamic>) return null;
    final name = error["name"] as String? ?? "Error";
    if (name == "MessageAbortedError") return null;
    final data = error["data"] as Map<String, dynamic>? ?? const {};
    final message = data["message"] as String? ?? "";
    final status = data["statusCode"];
    final suffix = status == null ? "" : " (HTTP $status)";
    return message.isEmpty ? "$name$suffix" : "$name$suffix: $message";
  }

  void _handlePartUpdated(Map<String, dynamic> props, StreamController<AgentEvent> controller, String chatId) {
    final part = props["part"] as Map<String, dynamic>?;
    if (part == null) return;

    final partType = part["type"] as String? ?? "";
    switch (partType) {
      case "tool":
        final toolName = part["tool"] as String? ?? "unknown";
        final callId = part["callID"] as String? ?? "";
        final state = part["state"] as Map<String, dynamic>? ?? {};
        final status = state["status"] as String? ?? "";
        final input = state["input"];

        switch (status) {
          case "pending":
          case "running":
            if (_seenTools.putIfAbsent(chatId, () => <String>{}).add(callId)) {
              controller.add(ToolCallEvent(ToolCall(
                id: callId,
                name: toolName,
                argumentsJson: input != null ? jsonEncode(input) : null,
                argumentsText: input is Map<String, dynamic> ? _inputToText(input) : null,
              )));
            }
          case "completed":
            controller.add(ToolResultEvent(ToolResult(
              callId: callId,
              returnCode: 0,
              output: state["output"] as String? ?? "",
            )));
          case "error":
            controller.add(ToolResultEvent(ToolResult(
              callId: callId,
              returnCode: 1,
              output: "",
              exceptionInfo: state["error"] as String?,
            )));
        }
    }
  }

  String _inputToText(Map<String, dynamic> input) {
    if (input["command"] is String) return input["command"] as String;
    if (input["filePath"] is String) return input["filePath"] as String;
    return jsonEncode(input);
  }

  @override
  Future<void> abort(String chatId) async {
    final sessionId = _chatToSession[chatId];
    if (sessionId != null) {
      try {
        await transport.abort(chatId, sessionId);
      } catch (_) {}
    }
    _eventSubs[chatId]?.cancel();
    _eventSubs.remove(chatId);
    final ctrl = _controllers[chatId];
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.add(const DoneEvent());
      await ctrl.close();
    }
    _controllers.remove(chatId);
  }



  @override
  Future<void> shutdown() async {
    await Future.wait(_eventSubs.values.map((sub) => sub.cancel()));
    _eventSubs.clear();
    for (final controller in _controllers.values) {
      if (!controller.isClosed) await controller.close();
    }
    _controllers.clear();
    _chatToSession.clear();
    await transport.disposeAll();
  }

  @override
  Future<void> resetSession(String chatId, {List<Message> history = const []}) async {
    final sessionId = _chatToSession.remove(chatId);
    if (sessionId != null) {
      try {
        await transport.deleteSession(chatId, sessionId);
      } catch (_) {}
    }
    _seenTools.remove(chatId);
    final transcript = _transcript(history);
    if (transcript.isNotEmpty) _pendingContext[chatId] = transcript;
  }

  /// What the fresh session is told about the conversation it missed.
  String _transcript(List<Message> history) {
    final buffer = StringBuffer();
    for (final message in history) {
      final text = message.plainText.trim();
      if (text.isEmpty) continue;
      buffer.writeln("${message.role.name}: $text");
      buffer.writeln();
    }
    final body = buffer.toString().trim();
    return body.isEmpty ? "" : "Earlier in this conversation:\n\n$body";
  }

  @override
  Future<List<ToolApproval>> pendingApprovals(String chatId) async => _approvals[chatId] ?? [];

  @override
  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response) async {
    final sessionId = _chatToSession[chatId];
    if (sessionId == null) return;
    await transport.respondPermission(
      chatId,
      sessionId,
      approvalId,
      response == ApprovalResponse.allow ? "once" : "reject",
    );
    _approvals[chatId]?.removeWhere((a) => a.id == approvalId);
  }

  @override
  Future<void> disposeChat(String chatId) async {
    final sub = _eventSubs.remove(chatId);
    _controllers[chatId]?.close();
    _controllers.remove(chatId);
    _approvals.remove(chatId);
    _seenTools.remove(chatId);
    _chatToSession.remove(chatId);
    await sub?.cancel();
    await transport.dispose(chatId);
  }

  @override
  Future<List<ModelOption>> availableModels() async {
    if (_chatToSession.isEmpty) return [];
    final chatId = _chatToSession.keys.first;
    try {
      final providers = await transport.providers(chatId);
      return _flattenModels(providers);
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<ModelOption>> listModelsStandalone() async {
    if (_chatToSession.isNotEmpty) return availableModels();
    // Deliberately not a chat directory: this server is thrown away, and
    // `chats/` is scanned for real chats.
    final scratch = Directory.systemTemp.createTempSync("agent-chat-models-");
    final chatId = const Uuid().v4();
    try {
      await transport.ensureServer(chatId, scratch.path);
      final providers = await transport.providers(chatId);
      return _flattenModels(providers);
    } catch (_) {
      return [];
    } finally {
      await transport.dispose(chatId);
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  List<ModelOption> _flattenModels(List<Map<String, dynamic>> providers) {
    final result = <ModelOption>[];
    for (final p in providers) {
      final providerId = p["id"] as String? ?? "";
      final models = p["models"] as Map<String, dynamic>? ?? {};
      for (final m in models.values) {
        final entry = m as Map<String, dynamic>? ?? {};
        result.add(ModelOption(
          providerId: providerId,
          modelId: entry["id"] as String? ?? "",
          label: entry["name"] as String?,
        ));
      }
    }
    return result;
  }
}