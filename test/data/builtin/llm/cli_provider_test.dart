import "dart:async";
import "dart:convert";
import "dart:io";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/mcp_tool_bridge.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/model_registry.dart";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:flutter_test/flutter_test.dart";

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
      ClaudeCliProvider.cacheRoot = p.join(dir.path, "cache");
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
      ClaudeCliProvider.cacheRoot = null;
      dir.deleteSync(recursive: true);
    });

    const tool = LlmTool(name: "echo", description: "says it", schema: {});
    const ask = LlmMessage(role: LlmRole.user, text: "use echo");

    Future<LlmCompletion> step(LlmClient client, List<LlmMessage> messages) =>
        client
            .stream(
              messages,
              model: "sonnet",
              tools: [tool],
              reasoningEffort: "minimal",
            )
            .last
            .then((chunk) => chunk as LlmCompletion);

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
        // Every session runs in the one folder in the cache, and its own
        // files sit apart from it.
        final root = p.join(dir.path, "cache", "claude-cli");
        expect(process.workingDirectory, p.join(root, "work"));
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
}
