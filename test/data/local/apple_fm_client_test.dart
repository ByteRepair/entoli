import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/apple_fm.dart";

// The Swift half behind a mock `agent_chat/apple_fm`: what Dart asks for and
// what it does with what the framework reports. The real channel has no
// implementation on a test host, so every test installs one and feeds the
// bridge through `handlePlatformMessage` — the same door Swift's `send`
// knocks on. `AppleFmBridge.shared` installs the one handler the mock's
// deliveries reach.
//
// Plain `test`s, not `testWidgets`: the client is protocol machinery driven
// by real futures, and a suspended generator under the fake clock is the
// hang that made the first of these need rewriting.
const channel = MethodChannel("agent_chat/apple_fm");

const sampleSchema = {
  "type": "object",
  "description": "arguments",
  "properties": {
    "path": {"type": "string", "description": "what to read"},
  },
  "required": ["path"],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final asked = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      asked.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    asked.clear();
  });

  Future<void> incoming(String method, [Object? arguments]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
    // The delivery's chain is microtasks through the broadcast; one zero
    // timer is the flush.
    await Future<void>.delayed(Duration.zero);
  }

  /// One breathing round before the client's request has reached the mock
  /// at all: an async* generator starts on the next microtask, not eagerly.
  Future<void> breathe() => Future<void>.delayed(Duration.zero);

  Map<Object?, Object?> outgoing(String method) => (asked
      .where((call) => call.method == method)
      .map((call) => call.arguments as Map<Object?, Object?>)
      .single);

  test("text streams, and the completion closes the stream", () async {
    final reply = AppleFmClient(const AppleFmProbe("available"))
        .stream(const [LlmMessage(role: LlmRole.user, text: "hello")],
            model: appleModelId)
        .toList();
    await breathe();

    final id = outgoing("generate")["id"];
    await incoming("text", {"id": id, "text": "Hello"});
    await incoming("text", {"id": id, "text": " there."});
    await incoming("done", {"id": id});

    final chunks = await reply;
    expect(
        chunks.whereType<LlmTextChunk>().map((c) => c.text).join(),
        "Hello there.");
    final completion = chunks.whereType<LlmCompletion>().single;
    expect(completion.message.text, "Hello there.");
    expect(completion.message.toolCalls, isEmpty);
    expect(completion.finishReason, "stop");
    // A clean close cancels nothing: the generation is over when the client
    // stops reading.
    expect(asked.where((call) => call.method == "cancel"), isEmpty);
  });

  test("a tool call is the handoff: report, end, cancel", () async {
    final reply = AppleFmClient(const AppleFmProbe("available"))
        .stream(
            const [
              LlmMessage(role: LlmRole.user, text: "list the files here"),
            ],
            model: appleModelId,
            tools: const [
              LlmTool(
                  name: "bash",
                  description: "run a command",
                  schema: sampleSchema),
            ])
        .toList();
    await breathe();

    final id = outgoing("generate")["id"];
    expect(outgoing("generate")["tools"], isNotEmpty);
    await incoming(
        "toolCall", {"id": id, "name": "bash", "arguments": "{\"path\":\"~\"}"});
    // The stream ends on the report rather than waiting for a `done` a
    // cancelled generation would never send.
    final chunks = await reply;
    final completion = chunks.whereType<LlmCompletion>().single;
    expect(completion.finishReason, "tool_calls");
    expect(completion.message.toolCalls.single.name, "bash");
    expect(completion.message.toolCalls.single.argumentsJson, "{\"path\":\"~\"}");
    // The handoff's stop is Swift's own — the generation is cancelled there
    // the moment it reports — so the client asks for nothing twice.
    expect(asked.where((call) => call.method == "cancel"), isEmpty);
  });

  test("what the request carries is the history worded, the prompt bare",
      () async {
    AppleFmClient(const AppleFmProbe("available"))
        .stream(const [
          LlmMessage(role: LlmRole.system, text: "sys one"),
          LlmMessage(role: LlmRole.system, text: "sys two"),
          LlmMessage(role: LlmRole.user, text: "find the file"),
          LlmMessage(
            role: LlmRole.assistant,
            text: "looking",
            toolCalls: [
              LlmToolCall(id: "c0", name: "read", argumentsJson: "{\"path\":\"a\"}")
            ],
          ),
          LlmMessage(role: LlmRole.tool, toolCallId: "c0", text: "its size"),
          LlmMessage(role: LlmRole.user, text: "and now?"),
        ], model: appleModelId)
        .toList();
    await breathe();

    final request = outgoing("generate");
    expect(request["model"], appleModelId);
    expect(request["instructions"], "sys one\n\nsys two");
    expect(request["prompt"], "and now?");
    final history = (request["history"] as List)
        .map((entry) => entry as Map<Object?, Object?>)
        .toList();
    expect(history, [
      {"role": "user", "text": "find the file"},
      {"role": "assistant", "text": "looking\n[Called read with {\"path\":\"a\"}]"},
      {"role": "user", "text": "[Result of the read call:]\nits size"},
    ]);
  });

  test("a framework failure is worded by its code", () async {
    final reply = AppleFmClient(const AppleFmProbe("available"))
        .stream(const [LlmMessage(role: LlmRole.user, text: "hi")],
            model: appleModelId)
        .toList();
    // Attached before anything is delivered: an error future that resolves
    // with nobody listening is an unhandled failure, not an expectation.
    final expectation = expectLater(
        reply,
        throwsA(isA<LlmException>()
            .having((e) => e.retryable, "retryable", true)));
    await breathe();
    final id = outgoing("generate")["id"];
    await incoming("error", {"id": id, "code": "rate-limit", "message": "soon"});
    await expectation;
  });

  test("an oversized conversation says so and is not retried", () async {
    final reply = AppleFmClient(const AppleFmProbe("available"))
        .stream(const [LlmMessage(role: LlmRole.user, text: "hi")],
            model: appleModelId)
        .toList();
    final expectation = expectLater(
        reply,
        throwsA(isA<LlmException>()
            .having((e) => e.retryable, "retryable", false)
            .having((e) => e.message, "message", contains("Compact"))));
    await breathe();
    final id = outgoing("generate")["id"];
    await incoming("error", {"id": id, "code": "context", "message": ""});
    await expectation;
  });

  test("the picker's rows are what the handshake announced", () {
    final base =
        AppleFm(const AppleFmProbe("available")).provider.models;
    expect(base, contains(appleModelId));
    expect(base, isNot(contains(mlxModels.first)),
        reason: "a build that links no MLX offers no MLX rows");

    final both =
        AppleFm(const AppleFmProbe("available", mlx: true)).provider.models;
    expect(both, containsAll([appleModelId, mlxModels.single]));
  });

  test("a model the device has not turned on says where the setting is",
      () async {
    await expectLater(
      AppleFmClient(const AppleFmProbe("not-enabled"))
          .stream(const [LlmMessage(role: LlmRole.user, text: "hi")],
              model: appleModelId)
          .toList(),
      throwsA(isA<LlmException>()
          .having((e) => e.message, "message", contains("Apple Intelligence"))),
    );
  });
}