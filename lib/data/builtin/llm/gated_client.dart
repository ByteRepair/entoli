import "dart:async";

import "llm_client.dart";
import "rate_limit_gate.dart";

/// Wraps an [LlmClient] so every [stream] call passes through a shared
/// [RateLimitGate]: bounded concurrency and a coordinated 429 cooldown.
///
/// One [GatedLlmClient] is built per turn in `BuiltinBackend.sendPrompt` and
/// handed to the parent agent and the [SubAgentRunner], so the two share one
/// gate. The [finally] block releases the slot on normal completion, a thrown
/// [LlmException], or cancel (the consumer stops listening).
class GatedLlmClient implements LlmClient {
  GatedLlmClient(this.inner, this.gate);

  final LlmClient inner;
  final RateLimitGate gate;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    await gate.acquire();
    try {
      yield* inner.stream(
        messages,
        model: model,
        tools: tools,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
      );
    } finally {
      gate.release();
    }
  }

  @override
  void close() => inner.close();
}
