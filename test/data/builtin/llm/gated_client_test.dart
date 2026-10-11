import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/gated_client.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/rate_limit_gate.dart";

import "../builtin_fakes.dart";
import "../../../harness.dart";

void main() {
  group("GatedLlmClient", () {
    test("stream() holds the concurrency cap", () async {
      final inner = FakeLlmClient([
        for (var i = 0; i < 6; i++) [const LlmCompletion(message: LlmMessage(role: LlmRole.assistant, text: "ok"))],
      ]);
      final tracking = ConcurrentFakeLlmClient(inner);
      final gate = RateLimitGate(maxConcurrent: 2);
      final client = GatedLlmClient(tracking, gate);

      await Future.wait(List.generate(6, (_) => client.stream(
        const [], model: "m",
      ).forEach((_) {})));

      expect(tracking.maxConcurrent, lessThanOrEqualTo(2));
    });

    test("releases the slot on a thrown LlmException", () async {
      final inner = FakeLlmClient([
        // turn 0 fails; turn 1 succeeds. The failure map makes the first
        // stream() throw before yielding anything.
        const [],
        [const LlmCompletion(message: LlmMessage(role: LlmRole.assistant, text: "ok"))],
      ])
        ..failures[0] = const LlmException("boom", statusCode: 500, retryable: false);
      final gate = RateLimitGate(maxConcurrent: 1);
      final client = GatedLlmClient(inner, gate);

      await expectLater(
        client.stream(const [], model: "m").toList(),
        throwsA(isA<LlmException>()),
      );
      // The slot is back: a second call acquires immediately rather than
      // hanging forever.
      await client.stream(const [], model: "m").forEach((_) {});
    });

    test("releases the slot when the consumer cancels mid-stream", () async {
      // A stream that emits once and then never completes on its own.
      final controller = StreamController<LlmChunk>();
      final inner = _SingleCallClient(controller.stream);
      final gate = RateLimitGate(maxConcurrent: 1);
      final client = GatedLlmClient(inner, gate);

      final seen = <LlmChunk>[];
      final sub = client.stream(const [], model: "m").listen(seen.add);
      // Mid-stream, not pre-acquire: a chunk has crossed before the cancel.
      controller.add(const LlmCompletion(message: LlmMessage(role: LlmRole.assistant, text: "first chunk")));
      await waitFor(() => seen.isNotEmpty, what: "the first chunk to cross");
      await sub.cancel();

      // No release to poll: the slot's fate is answered by the one below —
      // if it were not released, this acquire would never come back.
      final next = _SingleCallClient(Stream.fromIterable(
        const [LlmCompletion(message: LlmMessage(role: LlmRole.assistant, text: "ok"))],
      ));
      final client2 = GatedLlmClient(next, gate);
      await client2.stream(const [], model: "m").forEach((_) {});
      await controller.close();
    });

    test("listModels and close pass through", () async {
      final inner = FakeLlmClient(const []);
      final gate = RateLimitGate(maxConcurrent: 2);
      final client = GatedLlmClient(inner, gate);

      expect(await client.listModels(), ["fake-model"]);
      client.close();
      expect(inner.closed, isTrue);
    });
  });
}

/// A [LlmClient] that answers one [stream] call from a fixed [Stream].
class _SingleCallClient implements LlmClient {
  _SingleCallClient(this._stream);

  final Stream<LlmChunk> _stream;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) =>
      _stream;

  @override
  Future<List<String>> listModels() async => const [];

  @override
  void close() {}
}