import "../../domain/app_settings.dart";
import "../../domain/local_llm.dart";
import "../builtin/llm/llm_client.dart";
import "local_instance.dart";
import "prompt_cache.dart";
import "residency.dart";

/// The options the settings have. One mapper so the client that reaches a
/// model and the prefill that warms it read them the same way — a loaded model
/// is reused only under the same [LocalLoad], so a warm built from a different
/// reading would be thrown away rather than reused. `keptPrompts` collapses the
/// "Default (10)" the UI shows into the number the cache counts.
LocalOptions localOptions(AppSettings settings) => (
  device: settings.localModelDevice,
  contextLength: settings.localModelContext,
  maxRunning: settings.maxLocalModels,
  threads: settings.localModelThreads,
  keptPrompts:
      settings.localModelKvCachePrompts ?? AppSettings.defaultKvCachePrompts,
);

/// The on-device provider, as one client over whichever models are loaded.
///
/// Every model on disk is one entry in one provider, so the model named in a
/// request is what decides where it goes, and asking is also what loads it. A
/// turn is the same for every runtime: serve the model, restore its longest
/// saved prefix, generate, save. What a runtime does differently is inside its
/// [LocalInstance].
class LocalClient implements LlmClient {
  LocalClient(this._residency, this._options, {this._prompts});

  final Residency _residency;
  final LocalOptions Function() _options;

  /// Where prompts are kept between turns, or null where this build keeps
  /// none.
  final PromptCache? _prompts;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    final options = _options();
    final instance = await _serve(model, options);

    // Restore before, save after — content-addressed, so the whole of it is
    // this model's own and no chat id is anywhere in it. Best-effort by
    // construction: a miss just pays the prompt the way it did before. The
    // keys are hashed once here and handed to both halves.
    final prompts = _prompts;
    final lookup = prompts == null
        ? null
        : promptLookup(
            instance: instance,
            options: options,
            messages: messages,
            tools: tools,
          );
    if (prompts != null && lookup != null) {
      await prompts.warm(
        instance,
        namespace: lookup.namespace,
        keys: lookup.keys,
      );
    }

    yield* instance.generate(
      messages,
      tools: tools,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );

    if (prompts != null && lookup != null) {
      await prompts.keep(
        instance,
        namespace: lookup.namespace,
        key: lookup.keys.first,
        count: options.keptPrompts,
      );
    }
  }

  @override
  void close() {}

  /// Why it will never answer, as an [LlmException] — otherwise the agent's
  /// error arm reports a bare exception and the reason the model would not
  /// load, which is the only thing worth reading, is not in it.
  Future<LocalInstance> _serve(String model, LocalOptions options) async {
    try {
      return await _residency.serve(model, options);
    } on LocalLlmFailure catch (e) {
      throw LlmException(e.message);
    }
  }
}
