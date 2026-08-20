import "dart:async";

import "llm_client.dart";

/// Wraps an [LlmClient] whose endpoint is not answering yet, so a call waits
/// for it rather than failing against it.
///
/// This is the on-device model's, and it exists because loading one is slow in
/// a way no hosted provider is: mapping four gigabytes of weights takes the
/// better part of a minute on a phone, and the whole of that minute is time in
/// which the model is picked, is in the picker, and is what a chat is pinned
/// to. Without the wait the first turn after a launch fails with a refused
/// connection to localhost, which is both true and useless.
///
/// [ready] is re-read per call rather than held, since it is replaced every
/// time the server is started again.
class PendingLlmClient implements LlmClient {
  const PendingLlmClient(this.inner, this.ready);

  final LlmClient inner;
  final Future<void> Function() ready;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    await _wait();
    yield* inner.stream(
      messages,
      model: model,
      tools: tools,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );
  }

  /// Answered from the provider's own list rather than by asking, so this one
  /// does not wait: the model picker calls it, and a picker that blocked until
  /// a model had finished loading would be a settings page that hangs.
  @override
  Future<List<String>> listModels() => inner.listModels();

  /// Why it will never be ready, as an [LlmException] — otherwise the agent's
  /// error arm reports a bare `StateError` and the reason the model would not
  /// load, which is the only thing worth reading, is not in it.
  Future<void> _wait() async {
    try {
      await ready();
    } catch (e) {
      throw LlmException("$e");
    }
  }

  @override
  void close() => inner.close();
}
