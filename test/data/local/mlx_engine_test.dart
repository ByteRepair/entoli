import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/local_engine.dart";
import "package:agent_chat/data/local/mlx_engine.dart";
import "package:agent_chat/data/local/prompt_cache.dart";
import "package:agent_chat/data/model_host/model_host.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:agent_chat/domain/local_model.dart";

import "../../fakes.dart";
import "../../harness.dart" show tempDir;
import "apple_channel_mock.dart";

// What the engine asks the Swift half to load and evict, over
// [AppleChannelMock], and what a generation carries to name the model it runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final small = mlxCatalog[0], large = mlxCatalog[1];
  final channel = AppleChannelMock();
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
    const InProcessModelHost(),
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

  test(
    "a generation names the model, its directory and the whole conversation",
    () async {
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
      await channel.until("mlxGenerate");

      final generate = channel.outgoing("mlxGenerate");
      expect(generate["model"], small.id);
      expect(generate["directory"], mlx.store.downloadedOfSync(small.id)!.file);
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
    },
  );

  test("the leading system messages go as one", () async {
    final mlx = engine();
    final reply = mlx.client(() => AppSettings()).stream(const [
      LlmMessage(role: LlmRole.system, text: "body"),
      LlmMessage(role: LlmRole.system, text: "turn"),
      LlmMessage(role: LlmRole.user, text: "hi"),
    ], model: small.id).toList();
    await channel.until("mlxGenerate");

    // Qwen3.5's template raises on a system message past the first.
    final generate = channel.outgoing("mlxGenerate");
    expect(generate["messages"], [
      {"role": "system", "content": "body\n\nturn"},
      {"role": "user", "content": "hi"},
    ]);

    await channel.incoming("done", {"id": generate["id"]});
    await reply;
  });

  test("every tool call of a reply arrives before it ends", () async {
    final mlx = engine();
    final reply = mlx.client(() => AppSettings()).stream(const [
      LlmMessage(role: LlmRole.user, text: "two things"),
    ], model: small.id).toList();
    await channel.until("mlxGenerate");
    final id = channel.outgoing("mlxGenerate")["id"];

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

  test("prompt state is saved and restored in the cache's directory", () async {
    final dir = tempDir();
    final mlx = MlxEngine(
      FakeLocalModelStore(installed: {small.id}),
      const InProcessModelHost(),
      prompts: PromptCache(dir.path),
    );
    channel.answer = (call) =>
        call.method == "mlxSave" || call.method == "mlxRestore" ? true : null;

    final loaded = await mlx.serve(small.id, testLocalOptions(keptPrompts: 5));

    expect(await loaded.saveState("ns.key.bin"), isTrue);
    expect(await loaded.restoreState("ns.key.bin"), isTrue);
    expect(channel.outgoing("mlxSave"), {
      "model": small.id,
      "path": p.join(dir.path, "ns.key.bin"),
    });
    expect(
      channel.outgoing("mlxRestore")["path"],
      p.join(dir.path, "ns.key.bin"),
    );
  });

  test("with prompts not kept, nothing is saved", () async {
    final mlx = MlxEngine(
      FakeLocalModelStore(installed: {small.id}),
      const InProcessModelHost(),
      prompts: PromptCache(tempDir().path),
    );
    final loaded = await mlx.serve(small.id, testLocalOptions());

    expect(await loaded.saveState("ns.key.bin"), isFalse);
    expect(calls(), ["load ${small.id}"]);
  });

  test("how many may be resident and whether prompts are kept are offered", () {
    expect(engine().controls, {LocalControl.maxRunning, LocalControl.kvCache});
    expect(engine().catalog, mlxCatalog);
  });
}
