import "dart:async";
import "dart:convert";
import "dart:ffi" show Abi;
import "dart:io";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/mcp_tool_bridge.dart";
import "package:agent_chat/data/builtin/llm/providers/cli_sign_in.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/shell.dart" show guestHome, guestPath;
import "package:agent_chat/domain/model_registry.dart";
import "package:flutter/foundation.dart";
import "package:archive/archive.dart";
import "package:crypto/crypto.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:path/path.dart" as p;
import "package:flutter_test/flutter_test.dart";

import "../../../harness.dart" show tempDir;

/// A session that answers every exchange with one text reply, recording what
/// it was fed.
class _ScriptedSession extends CliSession {
  _ScriptedSession(super.spec, {this.hangs = false});

  /// Never gets past its first chunk.
  final bool hangs;

  final fed = <List<LlmMessage>>[];
  var closed = false;
  var pending = <String>[];

  @override
  bool get alive => !closed;

  @override
  bool accepts(List<LlmMessage> rest) => fed.isEmpty
      ? true
      : pending.isNotEmpty
      ? rest.every((m) => pending.contains(m.toolCallId))
      : rest.every((m) => m.role == LlmRole.user);

  /// Calls `t1` on its first exchange, then answers in text.
  @override
  Stream<LlmChunk> exchange(List<LlmMessage> rest) async* {
    fed.add(rest);
    yield const LlmTextChunk("…");
    if (hangs) await Completer<void>().future;
    final call = fed.length == 1;
    pending = call ? ["t1"] : [];
    yield LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: call ? "" : "done",
        toolCalls: [
          if (call) const LlmToolCall(id: "t1", name: "x", argumentsJson: "{}"),
        ],
      ),
    );
  }

  @override
  Future<void> close() async => closed = true;
}

class _ScriptedProvider extends CliProvider {
  _ScriptedProvider({this.hangs = false})
    : super(
        const LlmProviderConfig(id: "s", api: LlmApi.claudeCli, baseUrl: ""),
      );

  final bool hangs;
  final started = <_ScriptedSession>[];

  @override
  String get defaultCommand => "scripted";

  @override
  String get planName => "";

  @override
  String get workFolder => "scripted";

  @override
  List<String> get statusArguments => const [];

  @override
  List<String> get signInArguments => const [];

  @override
  List<String> get signOutArguments => const [];

  @override
  Map<String, String> homeEnvironment(String home) => const {};

  @override
  CliProvider withConfig(LlmProviderConfig config) => this;

  @override
  Future<CliRelease?> latestRelease(http.Client client) async => null;

  @override
  List<ModelInfo> get knownModels => const [];

  @override
  Future<CliSession> start(CliSessionSpec spec) async {
    final session = _ScriptedSession(spec, hangs: hangs);
    started.add(session);
    return session;
  }
}

const _system = LlmMessage(role: LlmRole.system, text: "be brief");
const _ask = LlmMessage(role: LlmRole.user, text: "hi");
const _useEcho = LlmMessage(role: LlmRole.user, text: "use echo");

/// One step of a CLI session's turn: [messages] sent with [tool] offered.
Future<LlmCompletion> _step(
  LlmClient client,
  List<LlmMessage> messages, {
  required String model,
  required LlmTool tool,
}) => client
    .stream(messages, model: model, tools: [tool], reasoningEffort: "minimal")
    .last
    .then((chunk) => chunk as LlmCompletion);

Future<LlmCompletion> _call(
  LlmClient client,
  List<LlmMessage> messages,
) async => (await client.stream(messages, model: "m").last) as LlmCompletion;

/// `claude` as the session sees it: the lines it writes are [sent], and
/// [reply] is what it would print back for one API message.
class _FakeProcess implements CliProcess {
  _FakeProcess(this.arguments, this.workingDirectory, this.environment);

  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;

  final _stdout = StreamController<String>();
  final stderr = StreamController<String>();
  final _exit = Completer<int>();
  final _inputClosed = Completer<void>();
  final sent = _Inbox<Map<String, dynamic>>();

  Future<void> get inputClosed => _inputClosed.future;

  @override
  Stream<String> get lines => _stdout.stream;

  @override
  Stream<String> get errors => stderr.stream;

  @override
  void writeLine(String line) =>
      sent.add(jsonDecode(line) as Map<String, dynamic>);

  /// Stdin closed is the end of its input, and so of it.
  @override
  Future<void> closeInput() async {
    if (!_inputClosed.isCompleted) _inputClosed.complete();
    exit(0);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void kill({bool force = false}) => exit(force ? -9 : -15);

  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  /// One line printed as it is.
  void say(Map<String, dynamic> line) => _stdout.add(jsonEncode(line));

  void _event(Map<String, dynamic> event) => _stdout.add(
    jsonEncode({
      "type": "stream_event",
      "event": event,
      "parent_tool_use_id": null,
    }),
  );

  /// One message of [blocks], text or tool use, ending with [stop], as the
  /// raw stream events `--include-partial-messages` prints.
  void reply(List<Map<String, dynamic>> blocks, String stop) {
    _event({
      "type": "message_start",
      "message": {
        "usage": {"input_tokens": 10, "output_tokens": 1},
      },
    });
    for (final (i, block) in blocks.indexed) {
      final text = block["type"] == "text";
      _event({
        "type": "content_block_start",
        "index": i,
        "content_block": text
            ? {"type": "text", "text": ""}
            : {"type": "tool_use", "id": block["id"], "name": block["name"]},
      });
      _event({
        "type": "content_block_delta",
        "index": i,
        "delta": text
            ? {"type": "text_delta", "text": block["text"]}
            : {
                "type": "input_json_delta",
                "partial_json": jsonEncode(block["input"]),
              },
      });
      _event({"type": "content_block_stop", "index": i});
    }
    _event({
      "type": "message_delta",
      "delta": {"stop_reason": stop},
      "usage": {"output_tokens": 5},
    });
    _event({"type": "message_stop"});
    if (stop != "tool_use") {
      _stdout.add(jsonEncode({"type": "result", "subtype": "success"}));
    }
  }
}

/// The launcher: each process it starts arrives on [started].
class _FakeLaunch {
  final started = _Inbox<_FakeProcess>();
  var calls = 0;

  Future<CliProcess> call(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    calls++;
    final process = _FakeProcess(arguments, workingDirectory, environment);
    started.add(process);
    return process;
  }
}

/// The bridge with no socket under it: a test plays the CLI by calling
/// [routes] directly.
class _FakeBridge implements ToolBridge {
  late McpToolRoutes routes;

  Future<ToolBridge> bind(
    List<LlmTool> tools,
    void Function(HeldToolCall call) onCall,
  ) async {
    routes = McpToolRoutes(tools, onCall);
    return this;
  }

  @override
  Map<String, dynamic> get config => const {"type": "fake"};

  final _closed = Completer<void>();

  /// The session's last act in closing.
  Future<void> get closed => _closed.future;

  @override
  Future<void> close() async {
    routes.failHeld();
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// What arrived, taken in order: [next] is the oldest not yet taken, or the
/// next to arrive.
class _Inbox<T> {
  final _waiting = <T>[];
  final _takers = <Completer<T>>[];

  void add(T item) =>
      _takers.isEmpty ? _waiting.add(item) : _takers.removeAt(0).complete(item);

  Future<T> get next {
    if (_waiting.isNotEmpty) return Future.value(_waiting.removeAt(0));
    final taker = Completer<T>();
    _takers.add(taker);
    return taker.future;
  }
}

/// The text a stream-json user line carries.
String _textOf(Map<String, dynamic> line) => [
  for (final block in line["message"]["content"] as List)
    if (block["type"] == "text") block["text"],
].join();

void main() {
  group("a CLI client", () {
    test(
      "carries a conversation in one session, fed only what is new",
      () async {
        final provider = _ScriptedProvider();
        final client = provider.client(null);
        final first = await _call(client, [_system, _ask]);
        final result = const LlmMessage(
          role: LlmRole.tool,
          toolCallId: "t1",
          text: "ok",
        );
        await _call(client, [_system, _ask, first.message, result]);

        expect(provider.started, hasLength(1));
        final session = provider.started.single;
        expect(session.spec.system, "be brief");
        expect(session.fed, [
          [_ask],
          [result],
        ]);
        client.close();
        expect(session.closed, isTrue);
      },
    );

    test("starts a fresh session for a conversation none has seen", () async {
      final provider = _ScriptedProvider();
      final client = provider.client(null);
      final first = await _call(client, [_ask]);
      // The same opening, but the loop's history went another way.
      await _call(client, [
        _ask,
        LlmMessage(
          role: LlmRole.assistant,
          text: "something else",
          toolCalls: first.message.toolCalls,
        ),
        const LlmMessage(role: LlmRole.tool, toolCallId: "t1", text: "ok"),
      ]);
      // A different system prompt is a different session too.
      await _call(client, [_system, _ask]);
      expect(provider.started, hasLength(3));
      client.close();
    });

    test("a call stopped part-way takes its session down", () async {
      final provider = _ScriptedProvider(hangs: true);
      final client = provider.client(null);
      final first = Completer<void>();
      final subscription = client.stream([_ask], model: "m").listen((_) {
        if (!first.isCompleted) first.complete();
      });
      // Started, and part-way: the session has said something and not ended.
      await first.future;
      await subscription.cancel();
      expect(provider.started.single.closed, isTrue);
      client.close();
    });
  });

  group("the MCP routes", () {
    late McpToolRoutes routes;
    final held = <HeldToolCall>[];

    setUp(() {
      held.clear();
      routes = McpToolRoutes(const [
        LlmTool(name: "echo", description: "says it back", schema: {}),
      ], held.add);
    });

    test("answer a notification with nothing", () async {
      expect(
        await routes.answer({
          "jsonrpc": "2.0",
          "method": "notifications/initialized",
        }),
        isNull,
      );
    });

    test("list the tools, and hold a call until it is answered", () async {
      final listed = await routes.answer({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
      });
      expect(listed!["result"]["tools"].single["name"], "echo");

      final call = routes.answer({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
          "name": "echo",
          "arguments": {"x": 1},
        },
      });
      expect(held.single.name, "echo");
      expect(held.single.arguments, {"x": 1});
      held.single.answer(const LlmMessage(role: LlmRole.tool, text: "1"));
      final answered = await call;
      expect(answered!["id"], 2);
      expect(answered["result"]["content"].single["text"], "1");
    });

    test("fail what is still held when told to", () async {
      final call = routes.answer({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "echo"},
      });
      routes.failHeld();
      expect((await call)!["result"]["isError"], isTrue);
    });
  });

  group("a Claude CLI session", () {
    late Directory dir;
    late _FakeLaunch launch;
    late _FakeBridge bridge;
    late CliProvider provider;

    setUp(() {
      dir = Directory.systemTemp.createTempSync("claude-cli-");
      CliProvider.cacheRoot = p.join(dir.path, "cache");
      final exe = File(p.join(dir.path, "claude"))..createSync();
      launch = _FakeLaunch();
      bridge = _FakeBridge();
      provider = ClaudeCliProvider.over(
        LlmProviderConfig(
          id: "c",
          api: LlmApi.claudeCli,
          baseUrl: "",
          command: exe.path,
          env: const {"FROM_CONFIG": "1"},
        ),
        launch: launch.call,
        bindBridge: bridge.bind,
      );
    });
    tearDown(() {
      CliProvider.cacheRoot = null;
      dir.deleteSync(recursive: true);
    });

    const tool = LlmTool(name: "echo", description: "says it", schema: {});
    const ask = _useEcho;

    Future<LlmCompletion> step(LlmClient client, List<LlmMessage> messages) =>
        _step(client, messages, model: "sonnet", tool: tool);

    test(
      "runs Entoli's tool through the held call and carries on in one process",
      () async {
        final client = provider.client(null);

        final firstStep = step(client, [_system, ask]);
        final process = await launch.started.next;
        expect(_textOf(await process.sent.next), "use echo");
        process.reply([
          {"type": "text", "text": "calling"},
          {
            "type": "tool_use",
            "id": "toolu_1",
            "name": "mcp__entoli__echo",
            "input": {"x": 1},
          },
        ], "tool_use");
        final first = await firstStep;
        expect(first.finishReason, "tool_use");
        expect(first.message.text, "calling");
        final call = first.message.toolCalls.single;
        expect(
          (call.id, call.name, call.argumentsJson),
          ("toolu_1", "echo", '{"x":1}'),
        );

        // The CLI calls the tool and waits; the loop's next step answers it.
        final called = bridge.routes.answer({
          "jsonrpc": "2.0",
          "id": 1,
          "method": "tools/call",
          "params": {
            "name": "echo",
            "arguments": {"x": 1},
          },
        });
        const result = LlmMessage(
          role: LlmRole.tool,
          toolCallId: "toolu_1",
          text: "one",
        );
        final secondStep = step(client, [_system, ask, first.message, result]);
        expect((await called)!["result"]["content"].first["text"], "one");
        process.reply([
          {"type": "text", "text": "echo said one"},
        ], "end_turn");
        final second = await secondStep;
        expect(second.message.text, "echo said one");

        const again = LlmMessage(role: LlmRole.user, text: "and now");
        final thirdStep = step(client, [
          _system,
          ask,
          first.message,
          result,
          second.message,
          again,
        ]);
        expect(_textOf(await process.sent.next), "and now");
        process.reply([
          {"type": "text", "text": "hello again"},
        ], "end_turn");
        final third = await thirdStep;
        expect(third.message.text, "hello again");
        expect(third.usage?.outputTokens, 5);
        expect(launch.calls, 1);

        final args = process.arguments;
        expect(args, containsAllInOrder(["--model", "sonnet"]));
        expect(args, containsAllInOrder(["--tools", ""]));
        expect(args, containsAllInOrder(["--permission-mode", "dontAsk"]));
        expect(args, containsAllInOrder(["--allowedTools", "mcp__entoli"]));
        expect(args, containsAllInOrder(["--effort", "low"]));
        final systemFile = args[args.indexOf("--system-prompt-file") + 1];
        expect(File(systemFile).readAsStringSync(), "be brief");
        final mcp = args[args.indexOf("--mcp-config") + 1];
        expect(jsonDecode(File(mcp).readAsStringSync()), {
          "mcpServers": {"entoli": bridge.config},
        });
        // Every session of an entry runs in that entry's folder in the
        // cache, told its own data folder, and its own files sit apart.
        final root = p.join(dir.path, "cache", "claude-cli");
        expect(process.workingDirectory, p.join(root, "work", "c"));
        expect(
          process.environment["CLAUDE_CONFIG_DIR"],
          p.join(root, "data", "c"),
        );
        expect(p.isWithin(p.join(root, "sessions"), systemFile), isTrue);
        expect(process.environment["FROM_CONFIG"], "1");

        client.close();
        await process.inputClosed;
        await bridge.closed;
      },
    );

    test("a program that ends mid-call says so, with what it said", () async {
      final client = provider.client(null);
      final pending = step(client, [_system, ask]);
      final process = await launch.started.next;
      await process.sent.next;
      process.stderr.add("signed out");
      await process.stderr.close();
      process.exit(1);
      await expectLater(
        pending,
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            "message",
            allOf(contains("exited (1)"), contains("signed out")),
          ),
        ),
      );
      client.close();
      await bridge.closed;
    });

    test("a program that is not there says so", () async {
      final missing = ClaudeCliProvider(
        LlmProviderConfig(
          id: "c",
          api: LlmApi.claudeCli,
          baseUrl: "",
          command: p.join(dir.path, "nothing"),
        ),
      );
      final client = missing.client(null);
      await expectLater(
        client.stream([_ask], model: "sonnet").drain<void>(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            "message",
            contains("does not exist"),
          ),
        ),
      );
      client.close();
    });
  });

  group("a Codex CLI session", () {
    late Directory dir;
    late _FakeLaunch launch;
    late CliProvider provider;

    setUp(() {
      dir = Directory.systemTemp.createTempSync("codex-cli-");
      CliProvider.cacheRoot = p.join(dir.path, "cache");
      final exe = File(p.join(dir.path, "codex"))..createSync();
      // The user's own Codex config, as the ChatGPT app leaves it.
      final home = Directory(p.join(dir.path, "codex-home"))..createSync();
      File(p.join(home.path, "config.toml")).writeAsStringSync(
        '[mcp_servers.node_repl]\ncommand = "node_repl"\n'
        "[mcp_servers.node_repl.env]\n",
      );
      launch = _FakeLaunch();
      provider = CodexCliProvider.over(
        LlmProviderConfig(
          id: "x",
          api: LlmApi.codexCli,
          baseUrl: "",
          command: exe.path,
          env: {"CODEX_HOME": home.path},
        ),
        launch: launch.call,
      );
    });
    tearDown(() {
      CliProvider.cacheRoot = null;
      dir.deleteSync(recursive: true);
    });

    const tool = LlmTool(
      name: "echo",
      description: "says it",
      schema: {"type": "object"},
    );
    const ask = _useEcho;

    Future<LlmCompletion> step(LlmClient client, List<LlmMessage> messages) =>
        _step(client, messages, model: "gpt-6-luna", tool: tool);

    /// The next request the session sent, which must be [method].
    Future<Map<String, dynamic>> request(
      _FakeProcess process,
      String method,
    ) async {
      final sent = await process.sent.next;
      expect(sent["method"], method);
      return sent;
    }

    /// Codex as far as an open thread: answers the handshake, and hands back
    /// the thread's start.
    Future<(_FakeProcess, Map<String, dynamic>)> opened() async {
      final process = await launch.started.next;
      final init = await request(process, "initialize");
      process.say({"id": init["id"], "result": {}});
      await request(process, "initialized");
      final start = await request(process, "thread/start");
      process.say({
        "id": start["id"],
        "result": {
          "thread": {"id": "th"},
        },
      });
      return (process, start["params"] as Map<String, dynamic>);
    }

    /// Answers `turn/start`, handing back its params.
    Future<Map<String, dynamic>> turn(_FakeProcess process) async {
      final start = await request(process, "turn/start");
      process.say({
        "id": start["id"],
        "result": {
          "turn": {"id": "t"},
        },
      });
      return start["params"] as Map<String, dynamic>;
    }

    void delta(_FakeProcess process, String text) => process.say({
      "method": "item/agentMessage/delta",
      "params": {"delta": text},
    });

    void call(_FakeProcess process, int request, String id, String text) =>
        process.say({
          "id": request,
          "method": "item/tool/call",
          "params": {
            "callId": id,
            "tool": "echo",
            "arguments": {"text": text},
          },
        });

    void completed(_FakeProcess process, [Map<String, dynamic>? error]) =>
        process.say({
          "method": "turn/completed",
          "params": {
            "turn": {
              "status": error == null ? "completed" : "failed",
              "error": error,
            },
          },
        });

    LlmMessage result(String id, String text) =>
        LlmMessage(role: LlmRole.tool, toolCallId: id, text: text);

    test(
      "runs Entoli's tools as the thread's own and carries on in one process",
      () async {
        final client = provider.client(null);

        final firstStep = step(client, [_system, ask]);
        final (process, thread) = await opened();
        expect(thread["model"], "gpt-6-luna");
        expect(thread["baseInstructions"], "be brief");
        expect(thread["ephemeral"], isTrue);
        expect(thread["environments"], isEmpty);
        expect(thread["dynamicTools"], [
          {
            "type": "function",
            "name": "echo",
            "description": "says it",
            "inputSchema": {"type": "object"},
          },
        ]);
        final first = await turn(process);
        expect(first["threadId"], "th");
        expect(first["effort"], "low");
        expect(first["input"], [
          {"type": "text", "text": "use echo"},
        ]);

        // Two calls made together are one reply.
        delta(process, "calling");
        call(process, 7, "c1", "a");
        call(process, 8, "c2", "b");
        final calls = await firstStep;
        expect(calls.finishReason, "tool_use");
        expect(calls.message.text, "calling");
        expect(
          [for (final c in calls.message.toolCalls) (c.id, c.argumentsJson)],
          [("c1", '{"text":"a"}'), ("c2", '{"text":"b"}')],
        );

        // The next step's results answer the requests Codex is waiting on.
        final history = [_system, ask, calls.message];
        final secondStep = step(client, [
          ...history,
          result("c2", "two"),
          result("c1", "one"),
        ]);
        final answers = {
          for (var i = 0; i < 2; i++)
            await process.sent.next.then(
              (a) => (a["id"], a["result"]["contentItems"][0]["text"]),
            ),
        };
        expect(answers, {(7, "one"), (8, "two")});
        delta(process, "echo said one and two");
        process.say({
          "method": "thread/tokenUsage/updated",
          "params": {
            "tokenUsage": {
              "last": {
                "inputTokens": 100,
                "cachedInputTokens": 60,
                "outputTokens": 5,
              },
            },
          },
        });
        completed(process);
        final second = await secondStep;
        expect(second.finishReason, "stop");
        expect(second.message.text, "echo said one and two");
        expect(
          (second.usage?.inputTokens, second.usage?.cacheReadTokens),
          (40, 60),
        );

        const again = LlmMessage(role: LlmRole.user, text: "and now");
        final thirdStep = step(client, [
          ...history,
          result("c2", "two"),
          result("c1", "one"),
          second.message,
          again,
        ]);
        expect((await turn(process))["input"], [
          {"type": "text", "text": "and now"},
        ]);
        delta(process, "hello again");
        completed(process);
        expect((await thirdStep).message.text, "hello again");
        expect(launch.calls, 1);

        // Codex's own tools are off, the user's MCP servers among them, and
        // every session runs in the one folder in the cache.
        final args = process.arguments;
        expect(args.first, "app-server");
        expect(args, containsAllInOrder(["-c", "features.shell_tool=false"]));
        expect(args, containsAllInOrder(["-c", 'web_search="disabled"']));
        expect(
          args,
          containsAllInOrder(["-c", "mcp_servers.node_repl.enabled=false"]),
        );
        expect(
          process.workingDirectory,
          p.join(dir.path, "cache", "codex-cli", "work", "x"),
        );
        // The entry names its own home, and what an entry says wins over
        // the folder Entoli would give it.
        expect(
          process.environment["CODEX_HOME"],
          p.join(dir.path, "codex-home"),
        );

        client.close();
        await process.inputClosed;
      },
    );

    test("a call that comes after its reply goes out with the next", () async {
      final client = provider.client(null);
      final firstStep = step(client, [_system, ask]);
      final (process, _) = await opened();
      await turn(process);
      call(process, 7, "c1", "a");
      final first = await firstStep;
      expect([for (final c in first.message.toolCalls) c.id], ["c1"]);

      // Codex made a second call while the loop was running the first.
      call(process, 8, "c2", "b");
      final second = await step(client, [
        _system,
        ask,
        first.message,
        result("c1", "one"),
      ]);
      expect((await process.sent.next)["id"], 7);
      expect(second.finishReason, "tool_use");
      expect([for (final c in second.message.toolCalls) c.id], ["c2"]);
      expect(launch.calls, 1);
      client.close();
    });

    test("an account that is not signed in says so", () async {
      final client = provider.client(null);
      final pending = step(client, [_system, ask]);
      final (process, _) = await opened();
      await turn(process);
      completed(process, {
        "message": "unexpected status 401 Unauthorized",
        "codexErrorInfo": {
          "httpConnectionFailed": {"httpStatusCode": 401},
        },
      });
      await expectLater(
        pending,
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            "message",
            contains("not signed in"),
          ),
        ),
      );
      client.close();
    });

    test("names the MCP servers a config declares, each once", () {
      expect(
        CodexCliProvider.mcpServersIn(
          "[mcp_servers.node_repl]\n"
          "[mcp_servers.node_repl.env]\n"
          '[mcp_servers."my server"]\n'
          "[plugins.x]\n",
        ),
        ["node_repl", "my server"],
      );
    });
  });

  group("the provider", () {
    test("is read from an entry by its API, whatever else it says", () {
      final provider = providerOf(
        const LlmProviderConfig(
          id: "c",
          api: LlmApi.claudeCli,
          baseUrl: "",
          catalogId: "anthropic",
        ),
      );
      expect(provider, isA<ClaudeCliProvider>());
      expect(provider.needsKey, isFalse);
      expect((provider as CliProvider).command, "claude");
      final codex = providerOf(
        const LlmProviderConfig(id: "x", api: LlmApi.codexCli, baseUrl: ""),
      );
      expect(codex, isA<CodexCliProvider>());
      expect((codex as CliProvider).command, "codex");
    });

    test("offers the CLI's model aliases beside the user's own, on a desktop "
        "alone", () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final provider = ClaudeCliProvider(
        const LlmProviderConfig(
          id: "c",
          api: LlmApi.claudeCli,
          baseUrl: "",
          customModels: [ModelInfo(id: "claude-opus-5")],
        ),
      );
      final ids = [for (final m in provider.models(ModelCatalog.current)) m.id];
      expect(ids.first, "claude-opus-5");
      expect(ids, containsAll(["opus", "sonnet", "haiku"]));

      // A CLI entry synced onto a phone has no program to run there.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(provider.models(ModelCatalog.current), isEmpty);
    });

    test("leaves a parent Claude Code session's variables behind", () {
      const provider = ClaudeCliProvider(
        LlmProviderConfig(id: "c", api: LlmApi.claudeCli, baseUrl: ""),
      );
      const own = {"HOME": "/home/u", "ANTHROPIC_API_KEY": "sk-1"};
      // Started from a Claude Code session: its variables are its own.
      expect(
        provider.inheritedFrom({
          ...own,
          "CLAUDECODE": "1",
          "CLAUDE_CODE_SESSION_ID": "s",
          "CLAUDE_CODE_USER_EMAIL": "a@b.test",
          "CLAUDE_AGENT_SDK_VERSION": "1",
          "ANTHROPIC_BASE_URL": "https://proxy.test",
          "MCP_CONNECTION_NONBLOCKING": "true",
        }),
        {"HOME": "/home/u"},
      );
      // Started from anywhere else: what the user exported is theirs.
      expect(provider.inheritedFrom(own), own);
    });

    test("finds Claude Desktop's copies, newest version first", () {
      final root = Directory.systemTemp.createTempSync("desktop-claude-");
      addTearDown(() => root.deleteSync(recursive: true));
      String copy(String version, String build) {
        final exe = p.join(
          root.path,
          version,
          build,
          "claude.app",
          "Contents",
          "MacOS",
          "claude",
        );
        File(exe).createSync(recursive: true);
        return exe;
      }

      final older = copy("2.1.9", "a");
      final newer = copy("2.1.317", "b");
      expect(ClaudeCliProvider.desktopCopiesIn(root.path), [newer, older]);
      expect(ClaudeCliProvider.desktopCopiesIn(p.join(root.path, "none")), []);
    });

    test("finds a bare name on the environment's PATH", () {
      final dir = Directory.systemTemp.createTempSync("cli-path-");
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, "claude")).writeAsStringSync("");
      final provider = ClaudeCliProvider(
        LlmProviderConfig(
          id: "c",
          api: LlmApi.claudeCli,
          baseUrl: "",
          env: {"PATH": dir.path},
        ),
      );
      expect(provider.locate(), p.join(dir.path, "claude"));
    });
  });

  group("Entoli's own copy", () {
    late Directory dir;
    setUp(() {
      dir = tempDir("cli-own-");
      CliProvider.cacheRoot = dir.path;
    });
    tearDown(() {
      CliProvider.cacheRoot = null;
      CliProvider.abi = Abi.current();
    });

    /// Anthropic's two files, for version [version] with [checksum] stated
    /// for darwin-arm64 and win32-x64.
    http.Client claudeReleases(String version, String checksum) =>
        MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith("/latest")) return http.Response("$version\n", 200);
          if (path.endsWith("/$version/manifest.json")) {
            return http.Response(
              jsonEncode({
                "version": version,
                "platforms": {
                  for (final p in ["darwin-arm64", "win32-x64"])
                    p: {"checksum": checksum, "size": 3},
                },
              }),
              200,
            );
          }
          return http.Response("", 404);
        });

    // Two entries on one program are two accounts: each is told its own
    // folder for everything the program keeps, and works in its own.
    test(
      "each provider keeps the program's data in a folder of its own",
      () async {
        ClaudeCliProvider entry(String id) =>
            ClaudeCliProvider(ClaudeCliProvider.preset.copyWith(id: id));
        final (a, b) = (entry("a"), entry("b"));
        final root = p.join(dir.path, "claude-cli");
        expect(a.dataDirectory, p.join(root, "data", "a"));
        expect(a.environment["CLAUDE_CONFIG_DIR"], a.dataDirectory);
        expect(b.environment["CLAUDE_CONFIG_DIR"], p.join(root, "data", "b"));
        expect(await a.workDirectory(), p.join(root, "work", "a"));
        expect(Directory(a.dataDirectory).existsSync(), isTrue);

        // Removed, it takes both with it, and the other entry keeps its own.
        await b.workDirectory();
        await a.forget();
        expect(Directory(p.join(root, "data", "a")).existsSync(), isFalse);
        expect(Directory(p.join(root, "work", "a")).existsSync(), isFalse);
        expect(Directory(b.dataDirectory).existsSync(), isTrue);
      },
    );

    test(
      "Claude CLI's release is its manifest's entry for this machine",
      () async {
        CliProvider.abi = Abi.macosArm64;
        final release = await const ClaudeCliProvider().latestRelease(
          claudeReleases("2.1.320", "ab"),
        );
        final claude = release!.files.single;
        expect(
          "${claude.url}",
          "${ClaudeCliProvider.releases}/2.1.320/darwin-arm64/claude",
        );
        expect(claude.sha256, "ab");
        expect(claude.packing, isA<BareProgram>());

        CliProvider.abi = Abi.windowsX64;
        final windows = await const ClaudeCliProvider().latestRelease(
          claudeReleases("2.1.320", "ab"),
        );
        expect(windows!.files.single.name, "claude.exe");

        // A machine the manifest has no build for has no release.
        CliProvider.abi = Abi.linuxArm64;
        expect(
          await const ClaudeCliProvider().latestRelease(
            claudeReleases("2.1.320", "ab"),
          ),
          isNull,
        );
      },
    );

    /// GitHub's answer for the latest Codex release, its assets as given.
    http.Client codexReleases(List<Map<String, dynamic>> assets) => MockClient(
      (request) async => request.url == CodexCliProvider.latestUrl
          ? http.Response(
              jsonEncode({"tag_name": "rust-v0.170.0", "assets": assets}),
              200,
            )
          : http.Response("", 404),
    );

    Map<String, dynamic> asset(String name, {String? digest = "sha256:cd"}) => {
      "name": name,
      "browser_download_url": "https://example.com/$name",
      "size": 3,
      "digest": ?digest,
    };

    test("Codex CLI's release is its program and its code-mode host, each "
        "built for this machine", () async {
      final assets = [
        for (final program in ["codex", "codex-code-mode-host"]) ...[
          asset("$program-x86_64-unknown-linux-musl.tar.gz"),
          asset("$program-x86_64-pc-windows-msvc.exe.zip"),
        ],
        asset("codex-aarch64-apple-darwin.tar.gz", digest: null),
        asset("codex-code-mode-host-aarch64-apple-darwin.tar.gz"),
        asset("codex-x86_64-apple-darwin.tar.gz"),
      ];
      CliProvider.abi = Abi.linuxX64;
      final linux = await const CodexCliProvider().latestRelease(
        codexReleases(assets),
      );
      // The host first, Codex last: its arrival is what says installed.
      expect(linux!.files.map((f) => f.name), [
        "codex-code-mode-host",
        "codex",
      ]);
      expect(
        linux.files.last.url.pathSegments.last,
        "codex-x86_64-unknown-linux-musl.tar.gz",
      );
      expect(linux.files.last.sha256, "cd");
      expect(linux.files.last.packing, isA<TarGzProgram>());

      CliProvider.abi = Abi.windowsX64;
      final windows = await const CodexCliProvider().latestRelease(
        codexReleases(assets),
      );
      expect(windows!.files.map((f) => f.name), [
        "codex-code-mode-host.exe",
        "codex.exe",
      ]);
      expect(windows.files.last.packing, isA<ZipProgram>());

      // No hash stated is nothing to check the download against.
      CliProvider.abi = Abi.macosArm64;
      await expectLater(
        const CodexCliProvider().latestRelease(codexReleases(assets)),
        throwsFormatException,
      );
      // A Codex without its host is not a release worth installing.
      CliProvider.abi = Abi.macosX64;
      expect(
        await const CodexCliProvider().latestRelease(codexReleases(assets)),
        isNull,
      );
    });

    List<int> tarGzOf(String program, List<int> bytes) =>
        GZipEncoder().encodeBytes(
          TarEncoder().encodeBytes(
            Archive()..addFile(
              ArchiveFile.bytes("$program-x86_64-unknown-linux-musl", bytes),
            ),
          ),
        );

    /// Codex's release for Linux, each program served as [archives] has it
    /// and stated to hash to what [digests] says.
    http.Client codexServing(
      Map<String, List<int>> archives,
      Map<String, String> digests,
    ) => MockClient((request) async {
      if (request.url == CodexCliProvider.latestUrl) {
        return http.Response(
          jsonEncode({
            "tag_name": "rust-v0.170.0",
            "assets": [
              for (final program in archives.keys)
                asset(
                  "$program-x86_64-unknown-linux-musl.tar.gz",
                  digest: "sha256:${digests[program]}",
                ),
            ],
          }),
          200,
        );
      }
      final program = archives.keys.firstWhere(
        (p) =>
            request.url.path.endsWith("/$p-x86_64-unknown-linux-musl.tar.gz"),
      );
      return http.Response.bytes(archives[program]!, 200);
    });

    /// Both programs as tarballs of [contents], and their true digests.
    ({Map<String, List<int>> archives, Map<String, String> digests}) codexOf(
      String contents,
    ) {
      final archives = {
        for (final program in ["codex", "codex-code-mode-host"])
          program: tarGzOf(program, utf8.encode("$contents $program")),
      };
      return (
        archives: archives,
        digests: {
          for (final MapEntry(:key, :value) in archives.entries)
            key: "${sha256.convert(value)}",
        },
      );
    }

    test("an install unpacks each program it checked, runnable, and is "
        "found first", () async {
      CliProvider.abi = Abi.linuxX64;
      final (:archives, :digests) = codexOf("#!/bin/sh");
      const codex = CodexCliProvider();
      await codex
          .install(client: codexServing(archives, digests))
          .drain<void>();

      expect(codex.installed, isTrue);
      final bin = p.dirname(codex.ownCopy);
      for (final program in ["codex", "codex-code-mode-host"]) {
        final file = File(p.join(bin, program));
        expect(file.readAsStringSync(), "#!/bin/sh $program");
        if (!Platform.isWindows) {
          expect(file.statSync().mode & 0x40, isNot(0));
        }
      }
      // Ahead of one on PATH: the copy the tour signed in.
      final path = Directory(p.join(dir.path, "path"))..createSync();
      File(p.join(path.path, "codex")).writeAsStringSync("");
      final withPath = CodexCliProvider(
        CodexCliProvider.preset.copyWith(env: {"PATH": path.path}),
      );
      expect(withPath.locate(), codex.ownCopy);

      // Without its host the copy is not whole, and is fetched again.
      File(p.join(bin, "codex-code-mode-host")).deleteSync();
      expect(codex.installed, isFalse);
    });

    test(
      "a download that does not match its checksum installs nothing",
      () async {
        CliProvider.abi = Abi.linuxX64;
        final (:archives, :digests) = codexOf("#!/bin/sh");
        const codex = CodexCliProvider();
        await expectLater(
          codex
              .install(
                client: codexServing(archives, {...digests, "codex": "00"}),
              )
              .drain<void>(),
          throwsFormatException,
        );
        expect(codex.installed, isFalse);
        expect(Directory(p.dirname(codex.ownCopy)).listSync(), isEmpty);
      },
    );
  });

  group("a sign-in", () {
    /// [cli] launching [process] for its sign-in and [status] for its
    /// status check, which exits [signedIn] 0 or 1.
    ({CliProvider cli, _FakeProcess login}) signingIn({
      required bool signedIn,
    }) {
      final login = _FakeProcess(const [], "", const {});
      final cli = CodexCliProvider.over(
        CodexCliProvider.preset.copyWith(command: Platform.resolvedExecutable),
        launch:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) async {
              if (arguments.first == "login" && arguments.length == 1) {
                return login;
              }
              return _FakeProcess(arguments, workingDirectory, environment)
                ..exit(signedIn ? 0 : 1);
            },
      );
      return (cli: cli, login: login);
    }

    test("finds the page in a line it prints, and ends signed in", () async {
      final (:cli, :login) = signingIn(signedIn: true);
      final signIn = await CliSignIn.start(cli);
      login._stdout.add(
        "Starting local login server on http://localhost:1455.",
      );
      login._stdout.add(
        "If your browser did not open, navigate to this URL to authenticate:",
      );
      login._stdout.add(
        "\x1b[94mhttps://auth.openai.com/oauth/authorize?x=1\x1b[0m",
      );
      expect(
        await signIn.page,
        Uri.parse("https://auth.openai.com/oauth/authorize?x=1"),
      );
      login.exit(0);
      expect(await signIn.result, isTrue);
    });

    test("exited 0 is not signed in until the program says so", () async {
      final (:cli, :login) = signingIn(signedIn: false);
      final signIn = await CliSignIn.start(cli);
      login.exit(0);
      expect(await signIn.page, isNull);
      expect(await signIn.result, isFalse);
    });
  });

  group("in Android's Linux", () {
    late Directory dir;
    late _Guest guest;
    setUp(() {
      dir = tempDir("cli-guest-");
      CliProvider.cacheRoot = dir.path;
      guest = _Guest();
      CliProvider.guest = guest;
    });
    tearDown(() {
      CliProvider.guest = null;
      CliProvider.cacheRoot = null;
      CliProvider.abi = Abi.current();
    });

    test("Android's builds are the musl ones its Alpine runs", () {
      expect(
        ClaudeCliProvider.platformOf(Abi.androidArm64),
        "linux-arm64-musl",
      );
      expect(
        CodexCliProvider.tripleOf(Abi.androidArm64),
        "aarch64-unknown-linux-musl",
      );
    });

    // Started through the guest with the program as its own first word, the
    // program's folder shared at its own path, and the guest's basics in
    // place of the app's environment, which is Android's.
    test(
      "a program is started in the guest, told the guest's basics",
      () async {
        final launched = <_FakeProcess>[];
        final claude = ClaudeCliProvider.over(
          ClaudeCliProvider.preset.copyWith(id: "g"),
          launch:
              (
                executable,
                arguments, {
                required workingDirectory,
                required environment,
              }) async {
                final process = _FakeProcess(
                  [executable, ...arguments],
                  workingDirectory,
                  environment,
                )..exit(0);
                launched.add(process);
                return process;
              },
        );
        File(claude.ownCopy).createSync(recursive: true);

        expect(await claude.signedIn(), isTrue);
        final process = launched.single;
        expect(process.arguments, [
          "proot",
          "-w",
          p.join(dir.path, "claude-cli", "work", "g"),
          claude.ownCopy,
          ...claude.statusArguments,
        ]);
        expect(guest.shared.single, [p.join(dir.path, "claude-cli")]);
        expect(process.environment["PATH"], guestPath);
        expect(process.environment["HOME"], guestHome);
        expect(process.environment["USE_BUILTIN_RIPGREP"], "0");
        expect(process.environment["CLAUDE_CONFIG_DIR"], claude.dataDirectory);
        expect(process.environment["PROOT_TMP_DIR"], "/guest/tmp");
      },
    );

    /// Anthropic's release of [program] for Android, its checksum true.
    http.Client claudeForAndroid(List<int> program) =>
        MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith("/latest")) return http.Response("2.1.320", 200);
          if (path.endsWith("/manifest.json")) {
            return http.Response(
              jsonEncode({
                "platforms": {
                  "linux-arm64-musl": {
                    "checksum": "${sha256.convert(program)}",
                    "size": program.length,
                  },
                },
              }),
              200,
            );
          }
          return http.Response.bytes(program, 200);
        });

    /// Claude CLI whose package installs in the guest exit with [code].
    ({ClaudeCliProvider claude, List<List<String>> ran}) installing(int code) {
      final ran = <List<String>>[];
      final claude = ClaudeCliProvider.over(
        ClaudeCliProvider.preset,
        launch:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) async {
              ran.add([executable, ...arguments]);
              return _FakeProcess(arguments, workingDirectory, environment)
                ..exit(code);
            },
      );
      return (claude: claude, ran: ran);
    }

    // What it needs on Alpine is installed in the guest before the program
    // is in place, so a copy that is installed has what it runs with.
    test(
      "an install puts the program's libraries in the guest first",
      () async {
        CliProvider.abi = Abi.androidArm64;
        final (:claude, :ran) = installing(0);
        await claude
            .install(client: claudeForAndroid(utf8.encode("#!/bin/sh")))
            .drain<void>();

        expect(claude.installed, isTrue);
        expect(ran.single, [
          "proot",
          "-w",
          p.join(dir.path, "claude-cli"),
          "apk",
          "add",
          "--no-cache",
          "libgcc",
          "libstdc++",
          "ripgrep",
        ]);
      },
    );

    test("an install whose libraries fail is not installed", () async {
      CliProvider.abi = Abi.androidArm64;
      final (:claude, ran: _) = installing(1);
      await expectLater(
        claude
            .install(client: claudeForAndroid(utf8.encode("#!/bin/sh")))
            .drain<void>(),
        throwsA(isA<LlmException>()),
      );
      expect(claude.installed, isFalse);
    });
  });
}

/// A guest that runs nothing: what it was asked to run is `proot -w <cwd>`
/// and the program's own words, what it shared is in [shared].
class _Guest implements CliGuest {
  final shared = <List<String>>[];

  @override
  ({List<String> command, Map<String, String> environment}) wrap(
    List<String> argv, {
    required String cwd,
    required List<String> shared,
  }) {
    this.shared.add(shared);
    return (
      command: ["proot", "-w", cwd, ...argv],
      environment: const {"PROOT_TMP_DIR": "/guest/tmp"},
    );
  }

  @override
  List<String> install(List<String> packages) => [
    "apk",
    "add",
    "--no-cache",
    ...packages,
  ];
}
