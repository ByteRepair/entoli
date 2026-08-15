// Desktop OpenCode backend: one `opencode serve` per chat, started lazily
// with the chat's workspace as working directory. All messages use
// POST /session/:id/prompt_async; events stream via SSE /event.
import "dart:async";
import "dart:convert";
import "dart:io";

import "package:uuid/uuid.dart";

import "../../core/config.dart";
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
  final Map<String, Set<String>> _reasoningParts = {};
  final Map<String, String> _pendingContext = {};

  /// A message that is nothing but `/name` plus arguments runs that command.
  /// The name may not contain a slash, so `/usr/bin/foo is broken` is prose.
  /// Anything else the composer's menu can offer has to dispatch here.
  static final _command = RegExp(r"^/([^\s/]+)(?:\s+([\s\S]*))?$");

  /// `@name` addresses an agent, but only where a word starts — an email
  /// address or a `user@host` is not a mention.
  static final _mention = RegExp(r"(?<=^|\s)@([\w.-]+)");

  @override
  BackendKind get kind => BackendKind.opencode;

  @override
  Future<Chat> createChat({String? title, String? model, String? provider}) =>
      newChat(config, kind: kind, title: title, model: model, provider: provider);

  @override
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const [], String? model, String? provider}) {
    final controller = StreamController<AgentEvent>();
    _controllers[chatId] = controller;
    // Returned rather than yielded, so the caller is listening before the turn
    // starts. Closing a controller nobody listens to never completes.
    unawaited(_runTurn(chatId, text, controller,
        model: model, provider: provider, attachments: attachments));
    return controller.stream;
  }

  Future<void> _runTurn(
    String chatId,
    String text,
    StreamController<AgentEvent> controller, {
    String? model,
    String? provider,
    List<Attachment> attachments = const [],
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

      final command = _command.firstMatch(text.trim());
      if (command != null) {
        // Awaited last: this one only returns when the turn is already over.
        await transport.runCommand(chatId, sessionId,
            name: command.group(1)!,
            arguments: command.group(2) ?? "",
            model: model,
            provider: provider,
            attachments: attachments);
      } else {
        await transport.promptAsync(chatId, sessionId,
            text: text,
            model: model,
            provider: provider,
            agents: _mention.allMatches(text).map((m) => m.group(1)!).toList(),
            attachments: attachments);
      }
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
        if (delta.isEmpty) return;
        final reasoning = _reasoningParts[chatId]?.contains(props["partID"]) ?? false;
        controller.add(reasoning ? ReasoningDelta(delta) : TextDelta(delta));

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
    // Part IDs never span turns, and a block left open by a failure would
    // otherwise sit in the map for the life of the chat.
    _reasoningParts.remove(chatId);
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
      case "reasoning":
        // Announced with a start time, its deltas follow, and it is announced
        // again with an end time and the whole text once the model is done.
        final id = part["id"] as String? ?? "";
        final time = part["time"] as Map<String, dynamic>? ?? const {};
        final end = (time["end"] as num?)?.toInt();
        if (end == null) {
          _reasoningParts.putIfAbsent(chatId, () => <String>{}).add(id);
          return;
        }
        _reasoningParts[chatId]?.remove(id);
        final start = (time["start"] as num?)?.toInt();
        controller.add(ReasoningEnd(
          text: part["text"] as String?,
          duration: start == null ? null : Duration(milliseconds: end - start),
        ));

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
    _reasoningParts.remove(chatId);
    final transcript = _transcript(history);
    if (transcript.isNotEmpty) _pendingContext[chatId] = transcript;
  }

  /// What the fresh session is told about the conversation it missed. Files
  /// are named rather than resent: only the turn being replayed carries its
  /// attachments back, so the rest are context the agent can ask about.
  String _transcript(List<Message> history) {
    final buffer = StringBuffer();
    for (final message in history) {
      final text = message.plainText.trim();
      final files = message.files.map((p) => p.filename).join(", ");
      if (text.isEmpty && files.isEmpty) continue;
      buffer.writeln("${message.role.name}: $text");
      if (files.isNotEmpty) buffer.writeln("(attached: $files)");
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
    _reasoningParts.remove(chatId);
    _chatToSession.remove(chatId);
    await sub?.cancel();
    await transport.dispose(chatId);
  }

  @override
  Future<List<ModelOption>> models() async {
    final live = _chatToSession.keys.firstOrNull;
    if (live != null) return _providersFrom(live);

    // No chat is running one, so borrow a server. Deliberately not a chat
    // directory: `chats/` is scanned for real chats.
    final scratch = Directory.systemTemp.createTempSync("agent-chat-models-");
    final chatId = const Uuid().v4();
    try {
      await transport.ensureServer(chatId, scratch.path);
      return await _providersFrom(chatId);
    } catch (_) {
      return [];
    } finally {
      await transport.dispose(chatId);
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  @override
  Future<List<CompletionOption>> completions(String chatId, CompletionKind kind) async {
    await transport.ensureServer(chatId, config.workspaceDir(chatId).path);
    // Hidden entries are opencode's own machinery: compaction, titling.
    return (await transport.completions(chatId, kind))
        .where((o) => o["hidden"] != true)
        .map(CompletionOption.fromJson)
        .toList();
  }

  Future<List<ModelOption>> _providersFrom(String chatId) async {
    try {
      return _flattenModels(await transport.providers(chatId));
    } catch (_) {
      return [];
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