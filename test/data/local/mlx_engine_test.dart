import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/apple_fm.dart";
import "package:agent_chat/data/local/local_engine.dart";
import "package:agent_chat/data/local/mlx_engine.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:agent_chat/domain/local_model.dart";

import "../../fakes.dart";

// The Swift half behind a mock `agent_chat/apple_fm`, as in
// `apple_fm_client_test.dart`: what the engine asks to load and evict, and
// what a generation carries to name the model it runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final small = mlxCatalog[0], large = mlxCatalog[1];
  final asked = <MethodCall>[];

  /// Load failures by model id, answered as the Swift half throws them.
  final refuse = <String, String>{};

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appleChannel, (call) async {
      asked.add(call);
      final model = (call.arguments as Map?)?["model"];
      if (call.method == "load" && refuse[model] != null) {
        throw PlatformException(code: "load", message: refuse[model]);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appleChannel, null);
    asked.clear();
    refuse.clear();
  });

  MlxEngine engine() =>
      MlxEngine(FakeLocalModelStore(installed: {small.id, large.id}));

  List<String> calls() => [
        for (final call in asked)
          "${call.method} ${(call.arguments as Map?)?["model"] ?? ""}".trim(),
      ];

  test("asking for a model loads it from its directory, once", () async {
    final mlx = engine();

    final directory = await mlx.serve(small.id);
    await mlx.serve(small.id);

    expect(calls(), ["load ${small.id}"]);
    expect((asked.single.arguments as Map)["directory"], directory);
    expect(mlx.running.value.single.phase, LocalLlmPhase.ready);
  });

  test("past the cap the least recently served is evicted first", () async {
    final mlx = engine();

    await mlx.serve(small.id);
    await mlx.serve(large.id);
    expect(calls(), ["load ${small.id}", "evict ${small.id}", "load ${large.id}"]);
    expect(mlx.running.value.map((s) => s.modelId), [large.id]);

    asked.clear();
    await mlx.serve(small.id, maxRunning: 2);
    expect(calls(), ["load ${small.id}"]);
    expect(mlx.running.value.map((s) => s.modelId), [large.id, small.id]);
  });

  test("a model that will not load says why, on its row and to the turn", () async {
    final mlx = engine();
    refuse[small.id] = "not enough memory";

    await expectLater(
      mlx.serve(small.id),
      throwsA(isA<LlmException>()
          .having((e) => e.message, "message", contains("not enough memory"))),
    );
    final row = mlx.running.value.single;
    expect(row.phase, LocalLlmPhase.failed);
    expect(row.failure, "not enough memory");
  });

  test("a model that is not downloaded is refused before the channel is asked",
      () async {
    await expectLater(engine().serve("gone"), throwsA(isA<LlmException>()));
    expect(asked, isEmpty);
  });

  test("unloading everything evicts every model", () async {
    final mlx = engine();
    await mlx.serve(small.id);

    await mlx.stopAll();

    expect(calls().last, "evictAll");
    expect(mlx.running.value, isEmpty);
  });

  test("a generation names the model and the directory it was loaded from",
      () async {
    final mlx = engine();
    final reply = mlx
        .client(() => AppSettings())
        .stream(const [LlmMessage(role: LlmRole.user, text: "hi")], model: small.id)
        .toList();
    // The load, then the generation behind it.
    for (var i = 0; i < 20 && !asked.any((call) => call.method == "generate"); i++) {
      await Future<void>.delayed(Duration.zero);
    }

    final generate = asked.singleWhere((call) => call.method == "generate").arguments as Map;
    expect(generate["model"], small.id);
    expect(generate["directory"], mlx.store.downloadedOfSync(small.id)!.file);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      appleChannel.name,
      appleChannel.codec.encodeMethodCall(MethodCall("done", {"id": generate["id"]})),
      (_) {},
    );
    expect((await reply).whereType<LlmCompletion>().single.finishReason, "stop");
  });

  test("only how many may be resident is offered to set", () {
    expect(engine().controls, {LocalControl.maxRunning});
    expect(engine().catalog, mlxCatalog);
  });
}
