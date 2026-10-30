import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/local_engine.dart";
import "package:agent_chat/data/local/mlx_engine.dart";
import "package:agent_chat/data/model_host/model_host.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:agent_chat/domain/local_model.dart";

import "../../fakes.dart";
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
    "a generation names the model and the directory it was loaded from",
    () async {
      final mlx = engine();
      final reply = mlx.client(() => AppSettings()).stream(const [
        LlmMessage(role: LlmRole.user, text: "hi"),
      ], model: small.id).toList();
      // The load, then the generation behind it.
      await channel.until("generate");

      final generate = channel.outgoing("generate");
      expect(generate["model"], small.id);
      expect(generate["directory"], mlx.store.downloadedOfSync(small.id)!.file);

      await channel.incoming("done", {"id": generate["id"]});
      expect(
        (await reply).whereType<LlmCompletion>().single.finishReason,
        "stop",
      );
    },
  );

  test("only how many may be resident is offered to set", () {
    expect(engine().controls, {LocalControl.maxRunning});
    expect(engine().catalog, mlxCatalog);
  });
}
