import "dart:io";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/local_engine.dart";
import "package:agent_chat/data/local/mlx_engine.dart";
import "package:agent_chat/data/local/prompt_cache.dart";
import "package:agent_chat/data/model_host/model_host.dart";
import "package:agent_chat/data/model_host/worker.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:agent_chat/domain/local_model.dart";

import "../../fakes.dart";
import "../../harness.dart" show tempDir;
import "channel_mock.dart";

// What the engine asks the Swift half to load and evict, over
// [ChannelMock], and what a generation carries to name the model it runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final small = mlxCatalog[0], large = mlxCatalog[1];
  final channel = ChannelMock(mlxChannel);
  final asked = channel.asked;

  /// Load failures by model id, answered as the Swift half throws them.
  final refuse = <String, String>{};

  setUp(() {
    channel.answer = (call) {
      final model = (call.arguments as Map?)?["model"];
      if (call.method == "load" && refuse[model] != null) {
        throw PlatformException(code: "load", message: refuse[model]);
      }
      return null;
    };
    channel.install();
  });

  tearDown(() {
    channel.uninstall();
    refuse.clear();
  });

  MlxEngine engine() => MlxEngine(
    FakeLocalModelStore(installed: {small.id, large.id}),
    const InAppModelProcess(),
  );

  List<String> calls() => [
    for (final call in asked)
      "${call.method} ${(call.arguments as Map?)?["model"] ?? ""}".trim(),
  ];

  test("asking for a model loads it from its directory, once", () async {
    final mlx = engine();

    final loaded = await mlx.serve(small.id, testLocalOptions());
    await mlx.serve(small.id, testLocalOptions());

    expect(calls(), ["load ${small.id}"]);
    expect((asked.single.arguments as Map)["directory"], loaded.model.file);
    expect(mlx.running.value.single.phase, LocalLlmPhase.ready);
  });

  test("past the cap the least recently served is evicted first", () async {
    final mlx = engine();

    await mlx.serve(small.id, testLocalOptions());
    await mlx.serve(large.id, testLocalOptions());
    expect(calls(), [
      "load ${small.id}",
      "evict ${small.id}",
      "load ${large.id}",
    ]);
    expect(mlx.running.value.map((s) => s.modelId), [large.id]);

    asked.clear();
    await mlx.serve(small.id, testLocalOptions(maxRunning: 2));
    expect(calls(), ["load ${small.id}"]);
    expect(mlx.running.value.map((s) => s.modelId), [large.id, small.id]);
  });

  test(
    "a model that will not load says why, on its row and to the turn",
    () async {
      final mlx = engine();
      refuse[small.id] = "not enough memory";

      await expectLater(
        mlx.serve(small.id, testLocalOptions()),
        throwsA(
          isA<LocalLlmFailure>().having(
            (e) => e.message,
            "message",
            contains("not enough memory"),
          ),
        ),
      );
      final row = mlx.running.value.single;
      expect(row.phase, LocalLlmPhase.failed);
      expect(row.failure, "not enough memory");
    },
  );

  test(
    "a model that is not downloaded is refused before the channel is asked",
    () async {
      await expectLater(
        engine().serve("gone", testLocalOptions()),
        throwsA(isA<LocalLlmFailure>()),
      );
      expect(asked, isEmpty);
    },
  );

  test("unloading everything evicts every model", () async {
    final mlx = engine();
    await mlx.serve(small.id, testLocalOptions());

    await mlx.stopAll();

    expect(calls().last, "evict ${small.id}");
    expect(mlx.running.value, isEmpty);
  });

  test("a generation names the model and the whole conversation", () async {
    final mlx = engine();
    final reply = mlx
        .client(() => AppSettings())
        .stream(
          const [
            LlmMessage(role: LlmRole.system, text: "be brief"),
            LlmMessage(role: LlmRole.user, text: "list it"),
            LlmMessage(
              role: LlmRole.assistant,
              text: "",
              toolCalls: [
                LlmToolCall(
                  id: "c0",
                  name: "bash",
                  argumentsJson: '{"c":"ls"}',
                ),
              ],
            ),
            LlmMessage(role: LlmRole.tool, text: "a.txt", toolCallId: "c0"),
          ],
          model: small.id,
          tools: const [
            LlmTool(
              name: "bash",
              description: "run",
              schema: {"type": "object"},
            ),
          ],
        )
        .toList();
    // The load, then the generation behind it.
    await channel.until("generate");

    final generate = channel.outgoing("generate");
    expect(generate["model"], small.id);
    // Every message, every call: the Swift half decides what to reuse.
    expect(generate["messages"], [
      {"role": "system", "content": "be brief"},
      {"role": "user", "content": "list it"},
      {
        "role": "assistant",
        "content": "",
        "toolCalls": [
          {"id": "c0", "name": "bash", "arguments": '{"c":"ls"}'},
        ],
      },
      {"role": "tool", "content": "a.txt", "toolCallId": "c0"},
    ]);
    expect((generate["tools"] as List).single, {
      "name": "bash",
      "description": "run",
      "schema": {"type": "object"},
    });

    await channel.incoming("done", {"id": generate["id"]});
    expect(
      (await reply).whereType<LlmCompletion>().single.finishReason,
      "stop",
    );
  });

  test("the leading system messages go as one", () async {
    final mlx = engine();
    final reply = mlx.client(() => AppSettings()).stream(const [
      LlmMessage(role: LlmRole.system, text: "body"),
      LlmMessage(role: LlmRole.system, text: "turn"),
      LlmMessage(role: LlmRole.user, text: "hi"),
    ], model: small.id).toList();
    await channel.until("generate");

    // Qwen3.5's template raises on a system message past the first.
    final generate = channel.outgoing("generate");
    expect(generate["messages"], [
      {"role": "system", "content": "body\n\nturn"},
      {"role": "user", "content": "hi"},
    ]);

    await channel.incoming("done", {"id": generate["id"]});
    await reply;
  });

  test("a reply whose model is unloaded under it ends saying so", () async {
    final mlx = engine();
    final reply = mlx.client(() => AppSettings()).stream(const [
      LlmMessage(role: LlmRole.user, text: "hi"),
    ], model: small.id).toList();
    await channel.until("generate");
    final ended = expectLater(
      reply,
      throwsA(
        isA<LlmException>()
            .having((e) => e.message, "message", contains("was unloaded"))
            .having((e) => e.retryable, "retryable", isFalse),
      ),
    );

    await channel.incoming("error", {
      "id": channel.outgoing("generate")["id"],
      "code": "unloaded",
      "message": "The model was unloaded.",
    });
    await ended;
  });

  test("every tool call of a reply arrives before it ends", () async {
    final mlx = engine();
    final reply = mlx.client(() => AppSettings()).stream(const [
      LlmMessage(role: LlmRole.user, text: "two things"),
    ], model: small.id).toList();
    await channel.until("generate");
    final id = channel.outgoing("generate")["id"];

    // Unlike the system model's framework, MLX reports every call and then
    // its end, so the first call is not the end of the reply.
    await channel.incoming("toolCall", {
      "id": id,
      "callId": "c0",
      "name": "read",
      "arguments": "{}",
    });
    await channel.incoming("toolCall", {
      "id": id,
      "callId": "c1",
      "name": "bash",
      "arguments": "{}",
    });
    await channel.incoming("done", {"id": id});

    final completion = (await reply).whereType<LlmCompletion>().single;
    expect(completion.finishReason, "tool_calls");
    expect(completion.message.toolCalls.map((c) => (c.id, c.name)), [
      ("c0", "read"),
      ("c1", "bash"),
    ]);
  });

  /// One turn on [small] through the client, its reply ending as [finish].
  Future<void> turn(MlxEngine mlx, AppSettings settings, String finish) async {
    final reply = mlx.client(() => settings).stream(const [
      LlmMessage(role: LlmRole.user, text: "hi"),
    ], model: small.id).toList();
    await channel.until("generate");
    final id = channel.outgoing("generate")["id"];
    if (finish == "tool_calls") {
      await channel.incoming("toolCall", {
        "id": id,
        "callId": "c0",
        "name": "read",
        "arguments": "{}",
      });
    }
    await channel.incoming("done", {"id": id});
    await reply;
  }

  test("a turn's prompt state is kept in the cache's directory", () async {
    final dir = tempDir();
    final mlx = MlxEngine(
      FakeLocalModelStore(installed: {small.id}),
      const InAppModelProcess(),
      prompts: PromptCache(dir.path),
    );
    channel.answer = (call) => call.method == "save" ? true : null;

    await turn(mlx, AppSettings(localModelKvCachePrompts: 5), "stop");

    final path = channel.outgoing("save")["path"] as String;
    expect(p.dirname(path), dir.path);
  });

  test("a step that ends in tool calls is not saved", () async {
    final mlx = MlxEngine(
      FakeLocalModelStore(installed: {small.id}),
      const InAppModelProcess(),
      prompts: PromptCache(tempDir().path),
    );

    // The next step is served by what the model still holds; a write of it
    // all per tool round would hold each one up for nothing.
    await turn(mlx, AppSettings(localModelKvCachePrompts: 5), "tool_calls");

    expect(calls(), isNot(contains("save ${small.id}")));
  });

  test("a reply stopped part-way is not taken for one the model still "
      "holds: the next turn restores what was kept", () async {
    final mlx = MlxEngine(
      FakeLocalModelStore(installed: {small.id}),
      const InAppModelProcess(),
      prompts: PromptCache(tempDir().path),
    );
    channel.answer = (call) {
      if (call.method == "save") {
        File((call.arguments as Map)["path"] as String).writeAsStringSync("");
        return true;
      }
      return call.method == "restore" ? true : null;
    };
    final settings = AppSettings(localModelKvCachePrompts: 5);
    await turn(mlx, settings, "stop");
    final kept = channel.outgoing("save")["path"];

    // The next turn is stopped while its prompt is read: the Swift half
    // drops what it held when a reply does not finish.
    const longer = [
      LlmMessage(role: LlmRole.user, text: "hi"),
      LlmMessage(role: LlmRole.assistant, text: "hello"),
      LlmMessage(role: LlmRole.user, text: "again"),
    ];
    asked.clear();
    final stopped = mlx
        .client(() => settings)
        .stream(longer, model: small.id)
        .listen((_) {});
    await channel.until("generate");
    final stopping = stopped.cancel();
    // A stop lands at the next frame the reply sends.
    await channel.incoming("text", {
      "id": channel.outgoing("generate")["id"],
      "text": "par",
    });
    await stopping;

    asked.clear();
    final again = mlx
        .client(() => settings)
        .stream(longer, model: small.id)
        .toList();
    await channel.until("generate");
    expect(channel.outgoing("restore")["path"], kept);
    await channel.incoming("done", {"id": channel.outgoing("generate")["id"]});
    await again;
  });

  test("with prompts not kept, nothing is saved", () async {
    final mlx = MlxEngine(
      FakeLocalModelStore(installed: {small.id}),
      const InAppModelProcess(),
      prompts: PromptCache(tempDir().path),
    );

    await turn(mlx, AppSettings(localModelKvCachePrompts: 0), "stop");

    expect(calls(), ["load ${small.id}", "generate ${small.id}"]);
  });

  test("a model whose process went says so on its row, is not evicted from "
      "the next one, and loads again when asked", () async {
    final process = _Dying();
    final mlx = MlxEngine(FakeLocalModelStore(installed: {small.id}), process);
    await mlx.serve(small.id, testLocalOptions());

    process.leases.single.lose();
    await pumpEventQueue();

    final row = mlx.running.value.single;
    expect(row.phase, LocalLlmPhase.failed);
    expect(row.failure, contains("model host quit"));

    asked.clear();
    await mlx.serve(small.id, testLocalOptions());
    expect(calls(), ["load ${small.id}"]);
    expect(mlx.running.value.single.phase, LocalLlmPhase.ready);
  });

  test("how many may be resident and whether prompts are kept are offered", () {
    expect(engine().controls, {LocalControl.maxRunning, LocalControl.kvCache});
    expect(engine().catalog, mlxCatalog);
  });
}

/// The models' process in this one, but one whose leases the test can end
/// the way a process that went ends them.
class _Dying implements ModelProcess {
  final leases = <ModelProcessLease>[];

  @override
  ModelChannel channel(String name) => const InAppModelProcess().channel(name);

  @override
  Future<Worker> spawn(WorkerKind kind, List<Object?> argument) =>
      throw UnimplementedError();

  @override
  Future<int?> footprint() async => null;

  @override
  ModelProcessLease hold() {
    final lease = ModelProcessLease(() {});
    leases.add(lease);
    return lease;
  }
}
