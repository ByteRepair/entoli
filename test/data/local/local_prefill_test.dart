import "dart:async";
import "dart:io";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/llama_engine.dart";
import "package:agent_chat/data/local/local_prefill.dart";
import "package:agent_chat/data/local/prompt_cache.dart";
import "package:agent_chat/domain/background_work.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "../../fakes.dart";
import "../../harness.dart";

// The real prefill over the real engine — residency, prompt cache and all —
// with only the runtime faked, so what is pinned is the shared code every
// runtime gets.

void main() {
  const model = "local-model";
  const messages = [
    LlmMessage(role: LlmRole.system, text: "system prompt body"),
    LlmMessage(role: LlmRole.user, text: "Hello"),
  ];
  const progress = LlmPromptProgress(processed: 1, total: 2, cache: 0);
  const token = LlmTextChunk("hi");

  late Directory cacheDir;
  setUp(() => cacheDir = tempDir());

  /// The cache and the count that turns it on are one knob: a cache passed
  /// with the count left at zero is a cache nothing reaches.
  LocalPrefill make(
    FakeLocalRuntime runtime,
    FakeBackgroundWork background, {
    bool cached = false,
  }) => LocalPrefill(
    engine: LlamaEngine(
      runtime,
      FakeLocalModelStore(installed: {model}),
      prompts: cached ? PromptCache(cacheDir.path) : null,
    ),
    background: background,
    warmup: testWarmup(kvCachePrompts: cached ? 30 : 0, messages: messages),
  );

  test(
    "warming serves the model and brackets it with a notification",
    () async {
      final runtime = FakeLocalRuntime(chunks: const [progress, token]);
      final background = FakeBackgroundWork();

      await make(runtime, background).warm(model);

      expect(runtime.served.map((s) => s.modelId), [model]);
      expect(runtime.generated.single, messages);
      expect(background.prefills.first, isNotNull);
      expect(background.prefills.last, isNull);
    },
  );

  test("a model that will not load is silent past the first notice", () async {
    final runtime = FakeLocalRuntime(ready: false);
    final background = FakeBackgroundWork();
    final prefill = make(runtime, background);

    await prefill.warm(model);

    expect(runtime.served, hasLength(1));
    expect(runtime.generated, isEmpty);
    expect(background.prefills.last, isNull);
    expect(prefill.state.value, isNull);
  });

  test("cancelling nothing does nothing", () async {
    final background = FakeBackgroundWork();
    await make(FakeLocalRuntime(), background).cancel();
    expect(background.prefills, isEmpty);
  });

  test("a saved body is the warm-up, and a miss saves one", () async {
    final keys = promptPrefixKeys(messages, const []);
    final background = FakeBackgroundWork();

    // A miss reads the prompt and saves the body under the shortest key.
    final cold = FakeLocalRuntime(chunks: const [progress, token]);
    await make(cold, background, cached: true).warm(model);
    expect(cold.generated, hasLength(1));
    expect(cold.saved.single, endsWith(".${keys.last}.bin"));

    // Hit: with the file there, restoring it is the whole warm-up — the
    // prompt is not sent and nothing is written back over it.
    File(p.join(cacheDir.path, cold.saved.single)).writeAsStringSync("state");
    final warm = FakeLocalRuntime(
      chunks: const [progress, token],
      restores: true,
    );
    await make(warm, background, cached: true).warm(model);
    expect(warm.restored.single, cold.saved.single);
    expect(warm.generated, isEmpty);
    expect(warm.saved, isEmpty);
  });

  test("the notification's Stop ends the warm-up mid-prompt", () async {
    final runtime = FakeLocalRuntime(chunks: const [progress, token])
      ..hold = Completer<void>();
    final background = FakeBackgroundWork();
    final prefill = make(runtime, background);
    final warming = prefill.warm(model);
    await waitFor(
      () => prefill.state.value?.fraction != null,
      what: "the prompt being read",
    );

    background.stop(BackgroundJob.prefill);
    // Ends where it is rather than when the held generation finally goes
    // on: the read is cancelled, not just marked superseded.
    await warming;

    expect(prefill.state.value, isNull);
    expect(background.prefills.last, isNull);
    runtime.hold!.complete();
  });
}
