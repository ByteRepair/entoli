import "dart:async";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;
import "dart:io";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/opencode/opencode_backend.dart";
import "package:agent_chat/data/opencode/opencode_models.dart";
import "package:agent_chat/data/opencode/opencode_transport.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";

/// Fake transport that records calls and feeds canned events.
class FakeOpencodeTransport implements OpencodeTransport {
  final List<String> ensureServerCalls = [];
  final List<({String chatId, String? title})> createSessionCalls = [];
  final List<({String sessionId, String text})> injectedContext = [];
  final List<String> deletedSessions = [];
  final List<({String permissionId, String response})> permissionReplies = [];
  final List<({String chatId, String sessionId, String text, String? model, String? provider})>
      promptAsyncCalls = [];
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
      {required String text, String? model, String? provider}) async {
    promptAsyncCalls.add(
        (chatId: chatId, sessionId: sessionId, text: text, model: model, provider: provider));
    _promptCompleters[chatId]?.complete();
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
    if (promptAsyncCalls.isNotEmpty) {
      c.complete();
    } else {
      _promptCompleters[chatId] = c;
    }
    return c;
  }
}

OcEvent _deltaEvent(String sessionId, String delta) => OcEvent(
      type: "message.part.delta",
      properties: {"sessionID": sessionId, "delta": delta},
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
  late Directory tmp;
  late AppConfig config;
  late FakeOpencodeTransport transport;
  late OpencodeBackend backend;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("opencode_backend_test_");
    config = AppConfig.forDirectory(tmp);
    final chats = Directory(p.join(tmp.path, "chats"));
    chats.createSync(recursive: true);
    transport = FakeOpencodeTransport();
    backend = OpencodeBackend(config: config, transport: transport);
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Start sendPrompt, wait for promptAsync to be called, then emit events.
  Future<List<AgentEvent>> runTurn(String chatId, String text, List<OcEvent> events) async {
    final completer = transport.waitForPrompt(chatId);
    final eventsFuture = backend.sendPrompt(chatId, text).toList();
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

    transport._controllers.remove(chat.state.id);

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
}

class _FailingTransport implements OpencodeTransport {
  @override
  Future<Uri> ensureServer(String chatId, String workspacePath) async {
    throw Exception("server failed to start");
  }

  @override
  Future<String> createSession(String chatId, {String? title}) async => "ses_1";

  @override
  Future<void> promptAsync(String chatId, String sessionId,
      {required String text, String? model, String? provider}) async {}

  @override
  Future<void> abort(String chatId, String sessionId) async {}

  @override
  Future<void> injectContext(String chatId, String sessionId, String text) async {}

  @override
  Future<void> deleteSession(String chatId, String sessionId) async {}

  @override
  Future<void> respondPermission(String chatId, String sessionId, String permissionId, String response) async {}

  @override
  Future<Stream<OcEvent>> subscribe(String chatId) async => const Stream.empty();

  @override
  Future<void> disposeAll() async {}

  @override
  Future<List<Map<String, dynamic>>> providers(String chatId) async => [];

  @override
  Future<void> dispose(String chatId) async {}
}