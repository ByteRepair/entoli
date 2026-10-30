import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/apple_fm.dart";

import "apple_channel_mock.dart";

// What Dart asks of the Swift half, and what it does with what the
// framework reports, over [AppleChannelMock]. `AppleFmBridge.shared`
// installs the one handler the mock's deliveries reach.
//
// Plain `test`s, not `testWidgets`: the client is protocol machinery driven
// by real futures, and a suspended generator under the fake clock is the
// hang that made the first of these need rewriting.

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

  final channel = AppleChannelMock();
  final asked = channel.asked;
  final incoming = channel.incoming;
  final breathe = channel.breathe;
  final outgoing = channel.outgoing;

  setUp(channel.install);
  tearDown(channel.uninstall);

  test("text streams, and the completion closes the stream", () async {
    final reply = AppleFmClient(const AppleFmProbe("available")).stream(const [
      LlmMessage(role: LlmRole.user, text: "hello"),
    ], model: appleModelId).toList();
    await breathe();

    final id = outgoing("generate")["id"];
    await incoming("text", {"id": id, "text": "Hello"});
    await incoming("text", {"id": id, "text": " there."});
    await incoming("done", {"id": id});

    final chunks = await reply;
    expect(
      chunks.whereType<LlmTextChunk>().map((c) => c.text).join(),
      "Hello there.",
    );
    final completion = chunks.whereType<LlmCompletion>().single;
    expect(completion.message.text, "Hello there.");
    expect(completion.message.toolCalls, isEmpty);
    expect(completion.finishReason, "stop");
    // A clean close cancels nothing: the generation is over when the client
    // stops reading.
    expect(asked.where((call) => call.method == "cancel"), isEmpty);
  });

  test("reasoning streams apart from the reply", () async {
    final reply = AppleFmClient(const AppleFmProbe("available")).stream(const [
      LlmMessage(role: LlmRole.user, text: "hello"),
    ], model: appleModelId).toList();
    await breathe();

    final id = outgoing("generate")["id"];
    await incoming("reasoning", {"id": id, "text": "The user "});
    await incoming("reasoning", {"id": id, "text": "said hello."});
    await incoming("text", {"id": id, "text": "Hello there."});
    await incoming("done", {"id": id});

    final chunks = await reply;
    expect(
      chunks.whereType<LlmReasoningChunk>().map((c) => c.text).join(),
      "The user said hello.",
    );
    final completion = chunks.whereType<LlmCompletion>().single;
    expect(completion.message.text, "Hello there.");
    expect(completion.message.reasoning, "The user said hello.");
  });

  test("a tool call is the handoff: report, end, cancel", () async {
    final reply = AppleFmClient(const AppleFmProbe("available"))
        .stream(
          const [LlmMessage(role: LlmRole.user, text: "list the files here")],
          model: appleModelId,
          tools: const [
            LlmTool(
              name: "bash",
              description: "run a command",
              schema: sampleSchema,
            ),
          ],
        )
        .toList();
    await breathe();

    final id = outgoing("generate")["id"];
    expect(outgoing("generate")["tools"], isNotEmpty);
    await incoming("toolCall", {
      "id": id,
      "name": "bash",
      "arguments": "{\"path\":\"~\"}",
    });
    // The stream ends on the report rather than waiting for a `done` a
    // cancelled generation would never send.
    final chunks = await reply;
    final completion = chunks.whereType<LlmCompletion>().single;
    expect(completion.finishReason, "tool_calls");
    expect(completion.message.toolCalls.single.name, "bash");
    expect(
      completion.message.toolCalls.single.argumentsJson,
      "{\"path\":\"~\"}",
    );
    // The handoff's stop is Swift's own — the generation is cancelled there
    // the moment it reports — so the client asks for nothing twice.
    expect(asked.where((call) => call.method == "cancel"), isEmpty);
  });

  test(
    "what the request carries is the history worded, the prompt bare",
    () async {
      AppleFmClient(const AppleFmProbe("available")).stream(const [
        LlmMessage(role: LlmRole.system, text: "sys one"),
        LlmMessage(role: LlmRole.system, text: "sys two"),
        LlmMessage(role: LlmRole.user, text: "find the file"),
        LlmMessage(
          role: LlmRole.assistant,
          text: "looking",
          toolCalls: [
            LlmToolCall(
              id: "c0",
              name: "read",
              argumentsJson: "{\"path\":\"a\"}",
            ),
          ],
        ),
        LlmMessage(role: LlmRole.tool, toolCallId: "c0", text: "its size"),
        LlmMessage(role: LlmRole.user, text: "and now?"),
      ], model: appleModelId).toList();
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
        {
          "role": "assistant",
          "text": "looking\n[Called read with {\"path\":\"a\"}]",
        },
        {"role": "user", "text": "[Result of the read call:]\nits size"},
      ]);
    },
  );

  test("a trailing tool result is the prompt, worded as one", () async {
    AppleFmClient(const AppleFmProbe("available")).stream(const [
      LlmMessage(role: LlmRole.user, text: "find the file"),
      LlmMessage(
        role: LlmRole.assistant,
        text: "",
        toolCalls: [LlmToolCall(id: "c0", name: "read", argumentsJson: "{}")],
      ),
      LlmMessage(role: LlmRole.tool, toolCallId: "c0", text: "its size"),
    ], model: appleModelId).toList();
    await breathe();

    expect(
      outgoing("generate")["prompt"],
      "[Result of the read call:]\nits size",
    );
  });

  test("a framework failure is worded by its code", () async {
    final reply = AppleFmClient(const AppleFmProbe("available")).stream(const [
      LlmMessage(role: LlmRole.user, text: "hi"),
    ], model: appleModelId).toList();
    // Attached before anything is delivered: an error future that resolves
    // with nobody listening is an unhandled failure, not an expectation.
    final expectation = expectLater(
      reply,
      throwsA(
        isA<LlmException>().having((e) => e.retryable, "retryable", true),
      ),
    );
    await breathe();
    final id = outgoing("generate")["id"];
    await incoming("error", {
      "id": id,
      "code": "rate-limit",
      "message": "soon",
    });
    await expectation;
  });

  test("an oversized conversation says so and is not retried", () async {
    final reply = AppleFmClient(const AppleFmProbe("available")).stream(const [
      LlmMessage(role: LlmRole.user, text: "hi"),
    ], model: appleModelId).toList();
    final expectation = expectLater(
      reply,
      throwsA(
        isA<LlmException>()
            .having((e) => e.retryable, "retryable", false)
            .having((e) => e.message, "message", contains("Compact")),
      ),
    );
    await breathe();
    final id = outgoing("generate")["id"];
    await incoming("error", {"id": id, "code": "context", "message": ""});
    await expectation;
  });

  test("the Apple provider offers the system model alone", () async {
    // MLX models are downloads, and the on-device provider's; a build that
    // links MLX adds nothing here.
    final models = await AppleFm(
      const AppleFmProbe("available", mlx: true),
    ).endpoint.listModels(null);
    expect(models, [appleModelId]);
  });

  test(
    "a model the device has not turned on says where the setting is",
    () async {
      await expectLater(
        AppleFmClient(const AppleFmProbe("not-enabled")).stream(const [
          LlmMessage(role: LlmRole.user, text: "hi"),
        ], model: appleModelId).toList(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            "message",
            contains("Apple Intelligence"),
          ),
        ),
      );
    },
  );
}
