import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/pending_client.dart";

import "../builtin_fakes.dart";

/// The on-device model is the only endpoint that is picked before it can
/// answer, and this is the whole of what that costs: a turn sent in the minute
/// a model takes to load waits for it instead of failing against a socket
/// nothing is listening on yet.
void main() {
  const reply = <LlmChunk>[
    LlmTextChunk("hello"),
    LlmCompletion(message: LlmMessage(role: LlmRole.assistant, text: "hello")),
  ];

  Future<List<LlmChunk>> drain(Stream<LlmChunk> stream) => stream.toList();

  test("the call waits for the server, then goes through unchanged", () async {
    final inner = FakeLlmClient([reply]);
    final loading = Completer<void>();
    final client = PendingLlmClient(inner, () => loading.future);
    var finished = false;

    final call = drain(client.stream(
      const [LlmMessage(role: LlmRole.user, text: "hi")],
      model: "qwen",
    )).then((chunks) {
      finished = true;
      return chunks;
    });
    await Future<void>.delayed(Duration.zero);

    // Nothing has been sent: the model is still being mapped.
    expect(inner.calls, isEmpty);
    expect(finished, isFalse);

    loading.complete();

    expect(await call, hasLength(2));
    expect(inner.calls.single.model, "qwen");
  });

  test("a server that will never answer says why, as an LlmException", () async {
    // Otherwise the agent's error arm reports a bare `StateError` and the
    // reason the model would not load — the only thing worth reading — is not
    // in it.
    final client = PendingLlmClient(
      FakeLlmClient([reply]),
      () => Future.error(StateError("not enough memory")),
    );

    await expectLater(
      drain(client.stream(const [], model: "qwen")),
      throwsA(isA<LlmException>()
          .having((e) => e.message, "message", contains("not enough memory"))),
    );
  });

  test("listing models does not wait", () async {
    // The model picker calls this, and a picker that blocked until a model had
    // finished loading would be a settings page that hangs.
    final inner = FakeLlmClient(const []);
    final client = PendingLlmClient(inner, () => Completer<void>().future);

    await expectLater(client.listModels(), completes);
  });

  test("readiness is re-read per call, not held", () async {
    // The server is started again whenever the model, the device or the context
    // changes, and each start replaces the future. A client holding the first
    // one would wait forever on a server that has since come up.
    var asked = 0;
    final client = PendingLlmClient(FakeLlmClient([reply, reply]), () async => asked++);

    await drain(client.stream(const [], model: "qwen"));
    await drain(client.stream(const [], model: "qwen"));

    expect(asked, 2);
  });
}
