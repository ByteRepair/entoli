import "dart:async";

import "package:flutter_test/flutter_test.dart";
import "dart:io";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/opencode/opencode_backend.dart";
import "package:agent_chat/data/opencode/opencode_models.dart";
import "package:agent_chat/data/opencode/opencode_transport.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";

import "../../fakes.dart";
import "../../harness.dart";

/// Fake transport that records calls and feeds canned events.
class FakeOpencodeTransport implements OpencodeTransport {
  final List<String> ensureServerCalls = [];
  final List<({String chatId, String? title})> createSessionCalls = [];
  final List<({String sessionId, String text})> injectedContext = [];
  final List<String> deletedSessions = [];
  final List<({String permissionId, String response})> permissionReplies = [];
  final List<
      ({
        String chatId,
        String sessionId,
        String text,
        String? model,
        String? provider,
        List<String> agents,
        List<Attachment> attachments,
      })> promptAsyncCalls = [];
  final List<
      ({
        String name,
        String arguments,
        String? model,
        String? provider,
        List<Attachment> attachments,
      })> commandCalls = [];
  final List<({String chatId, String sessionId})> abortCalls = [];
  final List<String> disposeCalls = [];

  final Map<String, StreamController<OcEvent>> _controllers = {};
  final Map<String, Completer<void>> _promptCompleters = {};

  @override
  Future<Uri> ensureServer(String chatId, String workspacePath) async {
    ensureServerCalls.add("$chatId:$workspacePath");
    _channel(chatId);
    return Uri.parse("http://127.0.0.1:0");
  }

  @override
  Future<String> createSession(String chatId, {String? title}) async {
    createSessionCalls.add((chatId: chatId, title: title));
    return "ses_${chatId}_123";
  }

  @override
  Future<void> promptAsync(String chatId, String sessionId,
      {required String text,
      String? model,
      String? provider,
      List<String> agents = const [],
      List<Attachment> attachments = const []}) async {
    promptAsyncCalls.add((
      chatId: chatId,
      sessionId: sessionId,
      text: text,
      model: model,
      provider: provider,
      agents: agents,
      attachments: attachments,
    ));
    _promptCompleters[chatId]?.complete();
  }

  @override
  Future<void> runCommand(String chatId, String sessionId,
      {required String name,
      required String arguments,
      String? model,
      String? provider,
      List<Attachment> attachments = const []}) async {
    commandCalls.add((
      name: name,
      arguments: arguments,
      model: model,
      provider: provider,
      attachments: attachments,
    ));
    _promptCompleters[chatId]?.complete();
    // Like the real endpoint, which holds its response until the turn is over.
    // Awaiting this before the events are streaming would deadlock the turn.
    await _channel(chatId).done;
  }

  @override
  Future<void> abort(String chatId, String sessionId) async {
    abortCalls.add((chatId: chatId, sessionId: sessionId));
  }

  @override
  Future<void> injectContext(String chatId, String sessionId, String text) async {
    injectedContext.add((sessionId: sessionId, text: text));
  }

  @override
  Future<void> deleteSession(String chatId, String sessionId) async {
    deletedSessions.add(sessionId);
  }

  @override
  Future<void> respondPermission(
      String chatId, String sessionId, String permissionId, String response) async {
    permissionReplies.add((permissionId: permissionId, response: response));
  }

  @override
  Future<Stream<OcEvent>> subscribe(String chatId) async => _channel(chatId).stream;

  /// A turn ends by closing the channel, so a second turn needs a fresh one.
  StreamController<OcEvent> _channel(String chatId) {
    final existing = _controllers[chatId];
    if (existing != null && !existing.isClosed) return existing;
    return _controllers[chatId] = StreamController<OcEvent>();
  }

  @override
  Future<List<Map<String, dynamic>>> providers(String chatId) async => [];

  Map<CompletionKind, List<Map<String, dynamic>>> scriptedCompletions = {};

  @override
  Future<List<Map<String, dynamic>>> completions(String chatId, CompletionKind kind) async =>
      scriptedCompletions[kind] ?? const [];

  @override
  Future<void> disposeAll() async {
    for (final chatId in _controllers.keys.toList()) {
      await dispose(chatId);
    }
  }

  @override
  Future<void> dispose(String chatId) async {
    disposeCalls.add(chatId);
    // Not awaited: closing a controller nobody ever listened to never
    // completes, and a server can be disposed without a turn having run.
    unawaited(_controllers.remove(chatId)?.close() ?? Future<void>.value());
  }

  void emit(String chatId, OcEvent event) {
    _channel(chatId).add(event);
  }

  void done(String chatId) {
    _controllers[chatId]?.close();
  }

  Completer<void> waitForPrompt(String chatId) {
    final c = Completer<void>();
    if (promptAsyncCalls.isNotEmpty || commandCalls.isNotEmpty) {
      c.complete();
    } else {
      _promptCompleters[chatId] = c;
    }
    return c;
  }
}

OcEvent _deltaEvent(String sessionId, String delta, {String? partId}) => OcEvent(
      type: "message.part.delta",
      properties: {"sessionID": sessionId, "delta": delta, "partID": ?partId},
    );

/// A reasoning part: announced with a start time, announced again with an end
/// time and the whole text once the model is done thinking.
OcEvent _reasoningEvent(
  String sessionId,
  String partId, {
  required int start,
  int? end,
  String text = "",
}) =>
    OcEvent(
      type: "message.part.updated",
      properties: {
        "sessionID": sessionId,
        "part": {
          "id": partId,
          "type": "reasoning",
          "text": text,
          "time": {"start": start, "end": ?end},
        },
      },
    );

OcEvent _toolUpdatedEvent(
  String sessionId,
  String callId,
  String tool,
  String status, {
  String? output,
  String? error,
  Map<String, dynamic>? input,
}) =>
    OcEvent(
      type: "message.part.updated",
      properties: {
        "sessionID": sessionId,
        "part": {
          "type": "tool",
          "callID": callId,
          "tool": tool,
          "state": {
            "status": status,
            "input": ?input,
            "output": ?output,
            "error": ?error,
          },
        },
      },
    );

OcEvent _idleEvent(String sessionId) => OcEvent(
      type: "session.idle",
      properties: {"sessionID": sessionId},
    );

void main() {
  late AppConfig config;
  late FakeOpencodeTransport transport;
  late OpencodeBackend backend;

  setUp(() {
    config = tempConfig("opencode_backend_test_");
    transport = FakeOpencodeTransport();
    backend = OpencodeBackend(config: config, transport: transport);
  });

  /// Start sendPrompt, wait for promptAsync to be called, then emit events.
  Future<List<AgentEvent>> runTurn(String chatId, String text, List<OcEvent> events,
      {List<Attachment> attachments = const []}) async {
    final completer = transport.waitForPrompt(chatId);
    final eventsFuture = backend.sendPrompt(chatId, text, attachments: attachments).toList();
    await completer.future.timeout(const Duration(seconds: 5));

    for (final e in events) {
      transport.emit(chatId, e);
    }
    transport.done(chatId);

    return eventsFuture.timeout(const Duration(seconds: 10));
  }

  test("createChat does not start a server", () async {
    final chat = await backend.createChat();
    expect(chat.state.id, isNotEmpty);
    expect(transport.ensureServerCalls, isEmpty);
    expect(transport.createSessionCalls, isEmpty);
  });

  test("createChat creates workspace and resources dirs", () async {
    final chat = await backend.createChat();
    expect(config.workspaceDir(chat.state.id).existsSync(), isTrue);
    expect(config.resourcesDir(chat.state.id).existsSync(), isTrue);
  });

  test("sendPrompt starts server, creates session, sends prompt_async", () async {
    final chat = await backend.createChat();

    await runTurn(chat.state.id, "hello", [_idleEvent("ses_${chat.state.id}_123")]);

    expect(transport.ensureServerCalls, hasLength(1));
    expect(transport.ensureServerCalls.first, contains(chat.state.id));
    expect(transport.createSessionCalls, hasLength(1));
    expect(transport.createSessionCalls.first.chatId, chat.state.id);
    expect(transport.promptAsyncCalls, hasLength(1));
    expect(transport.promptAsyncCalls.first.text, "hello");
  });

  test("sendPrompt streams text deltas into TextDelta events", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "hello", [
      _deltaEvent(sid, "Hello"),
      _deltaEvent(sid, " world"),
      _idleEvent(sid),
    ]);

    final textDeltas = events.whereType<TextDelta>().toList();
    expect(textDeltas, hasLength(2));
    expect(textDeltas[0].text, "Hello");
    expect(textDeltas[1].text, " world");
    expect(events.last, isA<DoneEvent>());
  });

  // Verbatim shape from opencode 1.18.18: thinking and the reply both stream
  // as message.part.delta, told apart only by the part they belong to.
  test("thinking streams apart from the reply", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "17*23?", [
      _reasoningEvent(sid, "prt_r1", start: 1000),
      _deltaEvent(sid, "17*23", partId: "prt_r1"),
      _deltaEvent(sid, " = 391", partId: "prt_r1"),
      _reasoningEvent(sid, "prt_r1", start: 1000, end: 3500, text: "17*23 = 391"),
      _deltaEvent(sid, "391", partId: "prt_t1"),
      _idleEvent(sid),
    ]);

    expect(events.whereType<ReasoningDelta>().map((e) => e.text), ["17*23", " = 391"]);
    expect(events.whereType<TextDelta>().map((e) => e.text), ["391"]);

    final ended = events.whereType<ReasoningEnd>().single;
    expect(ended.duration, const Duration(milliseconds: 2500));
    expect(ended.text, "17*23 = 391");
  });

  test("a second thinking block is timed on its own", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "hi", [
      _reasoningEvent(sid, "prt_r1", start: 1000),
      _reasoningEvent(sid, "prt_r1", start: 1000, end: 2000, text: "first"),
      _reasoningEvent(sid, "prt_r2", start: 5000),
      _deltaEvent(sid, "still here", partId: "prt_r2"),
      _reasoningEvent(sid, "prt_r2", start: 5000, end: 5500, text: "second"),
      _idleEvent(sid),
    ]);

    expect(
      events.whereType<ReasoningEnd>().map((e) => (e.text, e.duration)),
      [("first", const Duration(seconds: 1)), ("second", const Duration(milliseconds: 500))],
    );
    // The first block is closed, so its partID no longer claims a delta.
    expect(events.whereType<ReasoningDelta>().single.text, "still here");
  });

  test("sendPrompt streams tool call and result events", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "run pwd", [
      _toolUpdatedEvent(sid, "call_1", "bash", "pending", input: {"command": "pwd"}),
      _toolUpdatedEvent(sid, "call_1", "bash", "running"),
      _toolUpdatedEvent(sid, "call_1", "bash", "completed", output: "/workspace\n"),
      _deltaEvent(sid, "The output is /workspace"),
      _idleEvent(sid),
    ]);

    final toolCalls = events.whereType<ToolCallEvent>().toList();
    expect(toolCalls, hasLength(1));
    expect(toolCalls[0].call.name, "bash");
    expect(toolCalls[0].call.id, "call_1");
    expect(toolCalls[0].call.argumentsText, "pwd");

    final toolResults = events.whereType<ToolResultEvent>().toList();
    expect(toolResults, hasLength(1));
    expect(toolResults[0].result.callId, "call_1");
    expect(toolResults[0].result.output, "/workspace\n");
    expect(toolResults[0].result.returnCode, 0);

    final textDeltas = events.whereType<TextDelta>().toList();
    expect(textDeltas, hasLength(1));
  });

  test("tool with error status emits ToolResultEvent with exceptionInfo", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "run bad", [
      _toolUpdatedEvent(sid, "call_1", "bash", "pending", input: {"command": "bad"}),
      _toolUpdatedEvent(sid, "call_1", "bash", "error", error: "command not found"),
      _idleEvent(sid),
    ]);

    final toolResults = events.whereType<ToolResultEvent>().toList();
    expect(toolResults, hasLength(1));
    expect(toolResults[0].result.returnCode, 1);
    expect(toolResults[0].result.exceptionInfo, "command not found");
  });

  test("duplicate pending/running tool events only emit one ToolCallEvent", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "run pwd", [
      _toolUpdatedEvent(sid, "call_1", "bash", "pending", input: {"command": "pwd"}),
      _toolUpdatedEvent(sid, "call_1", "bash", "running"),
      _toolUpdatedEvent(sid, "call_1", "bash", "running"),
      _toolUpdatedEvent(sid, "call_1", "bash", "completed", output: "/workspace\n"),
      _idleEvent(sid),
    ]);

    final toolCalls = events.whereType<ToolCallEvent>().toList();
    expect(toolCalls, hasLength(1));
  });

  test("abort sends abort to transport and emits DoneEvent", () async {
    final chat = await backend.createChat();

    final completer = transport.waitForPrompt(chat.state.id);
    final eventsFuture = backend.sendPrompt(chat.state.id, "hello").toList();
    await completer.future.timeout(const Duration(seconds: 5));

    await backend.abort(chat.state.id);

    final events = await eventsFuture.timeout(const Duration(seconds: 5));

    expect(transport.abortCalls, hasLength(1));
    expect(transport.abortCalls.first.chatId, chat.state.id);
    expect(events.last, isA<DoneEvent>());
  });

  test("disposeChat disposes transport", () async {
    final chat = await backend.createChat();
    await backend.disposeChat(chat.state.id);
    expect(transport.disposeCalls, contains(chat.state.id));
  });

  test("second sendPrompt reuses existing session", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    await runTurn(chat.state.id, "hello", [_deltaEvent(sid, "hi"), _idleEvent(sid)]);


    await runTurn(chat.state.id, "again", [_deltaEvent(sid, "bye"), _idleEvent(sid)]);

    expect(transport.createSessionCalls, hasLength(1));
    expect(transport.promptAsyncCalls, hasLength(2));
    expect(transport.promptAsyncCalls[1].text, "again");
  });

  test("session.error surfaces the provider message as an ErrorEvent", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "hello", [
      OcEvent(type: "session.error", properties: {
        "sessionID": sid,
        "error": {
          "name": "APIError",
          "data": {"message": "usage limit reached", "statusCode": 429},
        },
      }),
    ]);

    final error = events.whereType<ErrorEvent>().single;
    expect(error.message, contains("usage limit reached"));
    expect(error.message, contains("429"));
    expect(events.last, isA<DoneEvent>());
  });

  test("a permission request reaches the UI and can be answered", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "delete everything", [
      OcEvent(type: "permission.asked", properties: {
        "sessionID": sid,
        "id": "per_1",
        "permission": "bash",
        "tool": {"name": "bash"},
        "metadata": {"command": "rm -rf /"},
      }),
      _idleEvent(sid),
    ]);

    final approval = events.whereType<ApprovalRequestEvent>().single.approval;
    expect(approval.id, "per_1");
    expect(approval.toolName, "bash");
    expect(approval.argumentsJson, contains("rm -rf /"));
    expect(await backend.pendingApprovals(chat.state.id), hasLength(1));

    await backend.respondApproval(chat.state.id, "per_1", ApprovalResponse.allow);
    // The endpoint's vocabulary is once/always/reject, not allow/deny.
    expect(transport.permissionReplies.single.response, "once");
    expect(await backend.pendingApprovals(chat.state.id), isEmpty);
  });

  test("denying a permission says reject", () async {
    final chat = await backend.createChat();
    await runTurn(chat.state.id, "hi", [_idleEvent("ses_${chat.state.id}_123")]);

    await backend.respondApproval(chat.state.id, "per_1", ApprovalResponse.deny);

    expect(transport.permissionReplies.single.response, "reject");
  });

  test("a permission answered elsewhere stops being pending", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    await runTurn(chat.state.id, "hi", [
      OcEvent(type: "permission.asked", properties: {
        "sessionID": sid,
        "id": "per_1",
        "permission": "bash",
      }),
      OcEvent(type: "permission.replied", properties: {"sessionID": sid, "id": "per_1"}),
      _idleEvent(sid),
    ]);

    expect(await backend.pendingApprovals(chat.state.id), isEmpty);
  });

  test("listing models leaves no chat directory behind", () async {
    final before = Directory(config.chatsDir.path).listSync().length;

    await backend.models();

    expect(Directory(config.chatsDir.path).listSync(), hasLength(before));
  });

  test("a retry status surfaces before the retries are exhausted", () async {
    // opencode reports each failed attempt on session.status; the terminal
    // session.error only lands ~70s later, once it gives up.
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "say hi", [
      OcEvent(type: "session.status", properties: {
        "sessionID": sid,
        "status": {
          "type": "retry",
          "attempt": 1,
          "message": "you (Yiannis128) have reached your session usage limit",
          "next": 1786748066695,
        },
      }),
      _idleEvent(sid),
    ]);

    final retry = events.whereType<RetryEvent>().single;
    expect(retry.attempt, 1);
    expect(retry.message, contains("usage limit"));
  });

  test("an ordinary busy status is not a retry", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "say hi", [
      OcEvent(type: "session.status", properties: {
        "sessionID": sid,
        "status": {"type": "busy"},
      }),
      _idleEvent(sid),
    ]);

    expect(events.whereType<RetryEvent>(), isEmpty);
  });

  test("a real ollama-cloud usage-limit event reaches the UI as an error", () async {
    // Captured verbatim from opencode 1.18.18 on a rate-limited account.
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "say hi", [
      OcEvent(type: "session.error", properties: {
        "sessionID": sid,
        "error": {
          "name": "APIError",
          "data": {
            "message": "you (Yiannis128) have reached your session usage limit, "
                "upgrade for higher limits: https://ollama.com/upgrade",
            "statusCode": 429,
            "isRetryable": true,
            "responseHeaders": {"content-type": "application/json"},
          },
        },
      }),
      _idleEvent(sid),
    ]);

    expect(
      events.whereType<ErrorEvent>().single.message,
      contains("reached your session usage limit"),
    );
  });

  test("an aborted message is not reported as an error", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";

    final events = await runTurn(chat.state.id, "hello", [
      OcEvent(type: "session.error", properties: {
        "sessionID": sid,
        "error": {
          "name": "MessageAbortedError",
          "data": {"message": "aborted"},
        },
      }),
    ]);

    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.last, isA<DoneEvent>());
  });

  test("resetSession drops the session and seeds the next one", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";
    await runTurn(chat.state.id, "hello", [_idleEvent(sid)]);

    await backend.resetSession(chat.state.id, history: [
      Message(id: "m1", role: MessageRole.user, createdAt: DateTime(2026), parts: [
        const MessagePart.text(text: "hello"),
      ]),
    ]);
    expect(transport.deletedSessions, [sid]);

    await runTurn(chat.state.id, "hello again", [_idleEvent(sid)]);

    expect(transport.createSessionCalls, hasLength(2));
    expect(transport.injectedContext.single.text, contains("user: hello"));
  });

  // The turn being replayed brings its own files; the rest are named so the
  // fresh session knows they existed.
  test("a seeded session is told which files the kept messages carried", () async {
    final chat = await backend.createChat();
    final sid = "ses_${chat.state.id}_123";
    await runTurn(chat.state.id, "hello", [_idleEvent(sid)]);

    await backend.resetSession(chat.state.id, history: [
      Message(id: "m1", role: MessageRole.user, createdAt: DateTime(2026), parts: const [
        MessagePart.file(resource: "r1-shot.png", filename: "shot.png", mimeType: "image/png"),
        MessagePart.text(text: "what is this"),
      ]),
    ]);
    await runTurn(chat.state.id, "again", [_idleEvent(sid)]);

    expect(transport.injectedContext.single.text, contains("(attached: shot.png)"));
  });

  test("a session created without a reset is not seeded", () async {
    final chat = await backend.createChat();
    await runTurn(chat.state.id, "hello", [_idleEvent("ses_${chat.state.id}_123")]);

    expect(transport.injectedContext, isEmpty);
  });

  test("server startup failure emits ErrorEvent then DoneEvent", () async {
    final chat = await backend.createChat();

    final failingTransport = _FailingTransport();
    final failingBackend = OpencodeBackend(config: config, transport: failingTransport);

    final events = await failingBackend
        .sendPrompt(chat.state.id, "hello")
        .toList()
        .timeout(const Duration(seconds: 10));

    expect(events.whereType<ErrorEvent>(), hasLength(1));
    expect(events.whereType<DoneEvent>(), hasLength(1));
  });

  test("attachments ride along with the prompt", () async {
    final chat = await backend.createChat();
    final attachment = testAttachment("shot.png", mimeType: "image/png");

    await runTurn(chat.state.id, "look", [_idleEvent("ses_${chat.state.id}_123")],
        attachments: [attachment]);

    expect(transport.promptAsyncCalls.single.attachments, [attachment]);
  });

  test("a command carries its attachments too", () async {
    final chat = await backend.createChat();
    final attachment = testAttachment("shot.png", mimeType: "image/png");

    await runTurn(chat.state.id, "/review", [_idleEvent("ses_${chat.state.id}_123")],
        attachments: [attachment]);

    expect(transport.commandCalls.single.attachments, [attachment]);
  });

  test("a message that is only a command runs it, arguments and all", () async {
    final chat = await backend.createChat();
    await runTurn(chat.state.id, "/review the last commit", [_idleEvent("ses_${chat.state.id}_123")]);

    expect(transport.promptAsyncCalls, isEmpty);
    expect(transport.commandCalls.single.name, "review");
    expect(transport.commandCalls.single.arguments, "the last commit");
  });

  test("a bare command runs with empty arguments", () async {
    final chat = await backend.createChat();
    await runTurn(chat.state.id, "/init", [_idleEvent("ses_${chat.state.id}_123")]);

    expect(transport.commandCalls.single.name, "init");
    expect(transport.commandCalls.single.arguments, "");
  });

  test("a leading path is prose, not a command", () async {
    final chat = await backend.createChat();
    await runTurn(chat.state.id, "/usr/bin/env is missing", [_idleEvent("ses_${chat.state.id}_123")]);

    expect(transport.commandCalls, isEmpty);
    expect(transport.promptAsyncCalls.single.text, "/usr/bin/env is missing");
  });

  test("@names in a message are sent as agent mentions", () async {
    final chat = await backend.createChat();
    await runTurn(chat.state.id, "@explore find it, then @general fix it",
        [_idleEvent("ses_${chat.state.id}_123")]);

    expect(transport.promptAsyncCalls.single.agents, ["explore", "general"]);
  });

  test("an address mid-word is not a mention", () async {
    final chat = await backend.createChat();
    await runTurn(chat.state.id, "mail me at a@b.com", [_idleEvent("ses_${chat.state.id}_123")]);

    expect(transport.promptAsyncCalls.single.agents, isEmpty);
  });

  test("completions come from the chat's own server, minus the hidden ones", () async {
    final chat = await backend.createChat();
    transport.scriptedCompletions = {
      CompletionKind.command: [
        {"name": "review", "description": "review changes"},
      ],
      CompletionKind.agent: [
        {"name": "explore", "description": "search"},
        {"name": "title", "hidden": true},
      ],
    };

    expect(await backend.completions(chat.state.id, CompletionKind.command), [
      const CompletionOption(name: "review", description: "review changes"),
    ]);
    expect(await backend.completions(chat.state.id, CompletionKind.agent), [
      const CompletionOption(name: "explore", description: "search"),
    ]);
    expect(transport.ensureServerCalls, isNotEmpty);
  });
}

/// The fake, but the server never comes up.
class _FailingTransport extends FakeOpencodeTransport {
  @override
  Future<Uri> ensureServer(String chatId, String workspacePath) async {
    throw Exception("server failed to start");
  }
}
