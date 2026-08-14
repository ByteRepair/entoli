// Desktop OpenCode backend: one `opencode serve` per chat, started lazily
// with the chat's workspace as working directory. All messages use
// POST /session/:id/prompt_async; events stream via SSE /event.
import "dart:async";
import "dart:convert";

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
      {List<Attachment> attachments = const [], String? model, String? provider}) async* {
    final controller = StreamController<AgentEvent>();
    _controllers[chatId] = controller;

    final outController = StreamController<AgentEvent>();
    controller.stream.listen(outController.add, onError: outController.addError, onDone: outController.close);

    try {
      await transport.ensureServer(chatId, config.workspaceDir(chatId).path);

      var sessionId = _chatToSession[chatId];
      if (sessionId == null) {
        sessionId = await transport.createSession(chatId);
        _chatToSession[chatId] = sessionId;
        final seed = _pendingContext.remove(chatId);
        if (seed != null) await transport.injectContext(chatId, sessionId, seed);
      }

      _eventSubs[chatId]?.cancel();
      _eventSubs[chatId] = transport.subscribe(chatId).listen(
        (event) => _handleEvent(event, chatId),
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

    yield* outController.stream;
  }

  Future<void> _handleEvent(OcEvent event, String chatId) async {
    final controller = _controllers[chatId];
    if (controller == null || controller.isClosed) return;

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

      case "session.error":
        final text = _errorText(props["error"]);
        if (text != null) controller.add(ErrorEvent(text));
        controller.add(const DoneEvent());
        await controller.close();

      case "session.idle":
        controller.add(const DoneEvent());
        await controller.close();

      case "session.next.text.delta":
        // Legacy event type — some versions still emit this.
        controller.add(TextDelta(props["delta"] as String? ?? ""));
    }
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
            if (!_toolSeen(chatId, callId)) {
              controller.add(ToolCallEvent(ToolCall(
                id: callId,
                name: toolName,
                argumentsJson: input != null ? jsonEncode(input) : null,
                argumentsText: input is Map<String, dynamic> ? _inputToText(input) : null,
              )));
              _markToolSeen(chatId, callId);
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

      case "text":
        // Full text snapshot — only emit if we haven't been streaming deltas.
        // The controller accumulates; a snapshot is useful as a fallback.
        // We skip these since deltas provide the streaming experience.
        break;
    }
  }

  String _inputToText(Map<String, dynamic> input) {
    if (input["command"] is String) return input["command"] as String;
    if (input["filePath"] is String) return input["filePath"] as String;
    return jsonEncode(input);
  }

  final Map<String, Set<String>> _seenTools = {};

  bool _toolSeen(String chatId, String callId) =>
      _seenTools[chatId]?.contains(callId) ?? false;

  void _markToolSeen(String chatId, String callId) {
    _seenTools.putIfAbsent(chatId, () => <String>{}).add(callId);
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

  final Map<String, String> _pendingContext = {};

  @override
  Future<void> resetSession(String chatId, {String? transcript}) async {
    final sessionId = _chatToSession.remove(chatId);
    if (sessionId != null) {
      try {
        await transport.deleteSession(chatId, sessionId);
      } catch (_) {}
    }
    _seenTools.remove(chatId);
    if (transcript != null && transcript.isNotEmpty) _pendingContext[chatId] = transcript;
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
      response == ApprovalResponse.allow ? "allow" : "deny",
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
    final chatId = const Uuid().v4();
    try {
      await transport.ensureServer(chatId, config.workspaceDir(chatId).path);
      final providers = await transport.providers(chatId);
      return _flattenModels(providers);
    } catch (_) {
      return [];
    } finally {
      await transport.dispose(chatId);
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