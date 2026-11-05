import "dart:async";
import "dart:convert";
import "dart:io";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/mcp_tool_bridge.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/model_registry.dart";
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

  group("the MCP bridge", () {
    late McpToolBridge bridge;
    final held = <HeldToolCall>[];

    setUp(() async {
      held.clear();
      bridge = await McpToolBridge.bind(const [
        LlmTool(name: "echo", description: "says it back", schema: {}),
      ], held.add);
    });
    tearDown(() => bridge.close());

    Future<(int, Map?)> post(Map body, {String? token}) async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(bridge.url);
        request.headers.set("authorization", "Bearer ${token ?? bridge.token}");
        request.write(jsonEncode(body));
        final response = await request.close();
        final text = await utf8.decodeStream(response);
        return (
          response.statusCode,
          text.isEmpty ? null : jsonDecode(text) as Map,
        );
      } finally {
        client.close();
      }
    }

    test("refuses a request without its token", () async {
      final (status, _) = await post({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
      }, token: "wrong");
      expect(status, HttpStatus.unauthorized);
    });

    test("lists the tools, and holds a call until it is answered", () async {
      final (_, listed) = await post({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
      });
      expect(listed!["result"]["tools"].single["name"], "echo");

      final call = post({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
          "name": "echo",
          "arguments": {"x": 1},
        },
      });
      while (held.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(held.single.name, "echo");
      expect(held.single.arguments, {"x": 1});
      held.single.answer(const LlmMessage(role: LlmRole.tool, text: "1"));
      final (_, answered) = await call;
      expect(answered!["result"]["content"].single["text"], "1");
    });
  });

  group("a Claude CLI session", () {
    late Directory dir;
    late String log;
    late CliProvider provider;

    setUp(() {
      dir = Directory.systemTemp.createTempSync("fake-claude-");
      ClaudeCliProvider.cacheRoot = p.join(dir.path, "cache");
      addTearDown(() => ClaudeCliProvider.cacheRoot = null);
      log = p.join(dir.path, "args.json");
      final script = p.join(dir.path, "claude");
      final fake = p.absolute(
        "test/data/builtin/llm/fixtures/fake_claude.dart",
      );
      File(script).writeAsStringSync('#!/bin/sh\nexec dart "$fake" "\$@"\n');
      Process.runSync("chmod", ["+x", script]);
      provider = ClaudeCliProvider(
        LlmProviderConfig(
          id: "c",
          api: LlmApi.claudeCli,
          baseUrl: "",
          command: script,
          env: {"FAKE_CLAUDE_LOG": log},
        ),
      );
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test(
      "runs Entoli's tool through the held call and carries on in one process",
      () async {
        final client = provider.client(null);
        const tool = LlmTool(name: "echo", description: "says it", schema: {});
        Future<LlmCompletion> step(List<LlmMessage> messages) async =>
            (await client
                    .stream(
                      messages,
                      model: "sonnet",
                      tools: [tool],
                      reasoningEffort: "minimal",
                    )
                    .last)
                as LlmCompletion;

        const ask = LlmMessage(role: LlmRole.user, text: "use echo");
        final first = await step([_system, ask]);
        expect(first.finishReason, "tool_use");
        expect(first.message.text, "calling");
        final call = first.message.toolCalls.single;
        expect(
          (call.id, call.name, call.argumentsJson),
          ("toolu_1", "echo", '{"x":1}'),
        );

        const result = LlmMessage(
          role: LlmRole.tool,
          toolCallId: "toolu_1",
          text: "one",
        );
        final second = await step([_system, ask, first.message, result]);
        expect(second.message.text, "tools [echo]; echo said one");

        const again = LlmMessage(role: LlmRole.user, text: "and now");
        final third = await step([
          _system,
          ask,
          first.message,
          result,
          second.message,
          again,
        ]);
        expect(third.message.text, "hello again");
        expect(third.usage?.outputTokens, 5);

        final args = (jsonDecode(File(log).readAsStringSync()) as List)
            .cast<String>();
        expect(args, containsAllInOrder(["--model", "sonnet"]));
        expect(args, containsAllInOrder(["--tools", ""]));
        expect(args, containsAllInOrder(["--permission-mode", "dontAsk"]));
        expect(args, containsAllInOrder(["--allowedTools", "mcp__entoli"]));
        expect(args, containsAllInOrder(["--effort", "low"]));
        expect(args, contains("--system-prompt-file"));
        // Every session runs in the one folder in the cache, never a fresh
        // one, and its own files sit apart from it.
        final work = p.join(dir.path, "cache", "claude-cli", "work");
        expect(
          File("$log.cwd").readAsStringSync(),
          Directory(work).resolveSymbolicLinksSync(),
        );
        final systemFile = args[args.indexOf("--system-prompt-file") + 1];
        expect(
          p.isWithin(
            p.join(dir.path, "cache", "claude-cli", "sessions"),
            systemFile,
          ),
          isTrue,
        );
        client.close();
      },
      timeout: const Timeout(Duration(seconds: 60)),
      skip: Platform.isWindows ? "the fake is a shell script" : false,
    );

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

    test("offers the CLI's model aliases beside the user's own", () {
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
