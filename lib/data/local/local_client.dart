import "../../domain/local_llm.dart";
import "../builtin/llm/llm_client.dart";
import "../builtin/llm/openai_client.dart";
import "local_instance.dart";
import "prompt_cache.dart";
import "residency.dart";

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
    // construction: a miss just pays the prompt the way it did before. Keyed
    // on the messages as the agent sent them, its two system messages apart,
    // so the body every chat shares is a key of its own.
    final entry = _prompts?.lookup(instance, options, messages, tools);
    await entry?.warm();

    String? finish;
    var finished = false;
    try {
      // One system message to the model: a chat template refuses a second.
      await for (final chunk in instance.generate(
        mergeLeadingSystem(messages),
        tools: tools,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
      )) {
        if (chunk is LlmCompletion) finish = chunk.finishReason;
        yield chunk;
      }
      finished = true;
    } finally {
      // Stopped by whoever was reading, or failed: what the model holds now
      // is the runtime's to say, not the cache's to remember.
      if (!finished) entry?.unfinished();
    }

    // Saved where the turn ends, not at every step of it: the next step is
    // served by what the model still holds, and a write of the whole state
    // per tool round would hold each one up for nothing.
    if (finish != "tool_calls") await entry?.keep();
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
