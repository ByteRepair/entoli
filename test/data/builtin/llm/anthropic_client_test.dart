import "dart:convert";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

import "package:agent_chat/data/builtin/llm/anthropic_client.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";

import "sse.dart";

void main() {
  late List<http.BaseRequest> requests;

  AnthropicClient clientStreaming(List<Map<String, Object?>> events) {
    requests = [];
    return AnthropicClient(
      baseUrl: Uri.parse("https://example.test/v1"),
      apiKey: "sk-ant-test",
      httpClient: MockClient.streaming((request, _) async {
        requests.add(request);
        return anthropicSse(events);
      }),
    );
  }

  Map<String, dynamic> sentBody() =>
      jsonDecode((requests.single as http.Request).body)
          as Map<String, dynamic>;

  Map<String, Object?> blockStart(int index, Map<String, Object?> block) => {
    "type": "content_block_start",
    "index": index,
    "content_block": block,
  };

  Map<String, Object?> blockDelta(int index, Map<String, Object?> delta) => {
    "type": "content_block_delta",
    "index": index,
    "delta": delta,
  };

  group("streaming", () {
    test("text blocks arrive in pieces and assemble into the reply", () async {
      final chunks = await clientStreaming([
        {"type": "message_start"},
        blockStart(0, {"type": "text", "text": ""}),
        blockDelta(0, {"type": "text_delta", "text": "Hel"}),
        blockDelta(0, {"type": "text_delta", "text": "lo"}),
        {"type": "content_block_stop", "index": 0},
        {
          "type": "message_delta",
          "delta": {"stop_reason": "end_turn"},
        },
        {"type": "message_stop"},
      ]).stream(const [], model: "claude-test").toList();

      expect(chunks.whereType<LlmTextChunk>().map((c) => c.text), [
        "Hel",
        "lo",
      ]);
      final completion = chunks.whereType<LlmCompletion>().single;
      expect(completion.message.text, "Hello");
      expect(completion.stop, LlmStop.answered);
    });

    test("thinking keeps its signature, so the turn can be replayed", () async {
      final chunks = await clientStreaming([
        blockStart(0, {"type": "thinking", "thinking": ""}),
        blockDelta(0, {"type": "thinking_delta", "thinking": "let me see"}),
        blockDelta(0, {"type": "signature_delta", "signature": "sig-abc"}),
        {"type": "content_block_stop", "index": 0},
        blockStart(1, {"type": "text", "text": ""}),
        blockDelta(1, {"type": "text_delta", "text": "done"}),
      ]).stream(const [], model: "claude-test").toList();

      expect(chunks.whereType<LlmReasoningChunk>().single.text, "let me see");
      final message = chunks.whereType<LlmCompletion>().single.message;
      expect(message.reasoning, "let me see");
      expect(message.reasoningSignature, "sig-abc");
      expect(message.text, "done");

      // Reported while the block is still the last thing that happened, so it
      // can be closed already holding it rather than written again later.
      expect(
        chunks.whereType<LlmReasoningSignature>().single.signature,
        "sig-abc",
      );
      expect(
        chunks.indexWhere((c) => c is LlmReasoningSignature),
        lessThan(chunks.indexWhere((c) => c is LlmTextChunk)),
      );
    });

    test("a tool call's input is rebuilt from its partial JSON", () async {
      final chunks = await clientStreaming([
        blockStart(0, {"type": "tool_use", "id": "toolu_1", "name": "bash"}),
        blockDelta(0, {
          "type": "input_json_delta",
          "partial_json": "{\"command\"",
        }),
        blockDelta(0, {
          "type": "input_json_delta",
          "partial_json": ": \"ls\"}",
        }),
        {"type": "content_block_stop", "index": 0},
        {
          "type": "message_delta",
          "delta": {"stop_reason": "tool_use"},
        },
      ]).stream(const [], model: "claude-test").toList();

      final call = chunks
          .whereType<LlmCompletion>()
          .single
          .message
          .toolCalls
          .single;
      expect(call.id, "toolu_1");
      expect(call.name, "bash");
      expect(jsonDecode(call.argumentsJson), {"command": "ls"});
    });

    test("a tool call that streamed no input is still valid JSON", () async {
      final chunks = await clientStreaming([
        blockStart(0, {"type": "tool_use", "id": "toolu_1", "name": "bash"}),
        {"type": "content_block_stop", "index": 0},
      ]).stream(const [], model: "claude-test").toList();

      expect(
        chunks
            .whereType<LlmCompletion>()
            .single
            .message
            .toolCalls
            .single
            .argumentsJson,
        "{}",
      );
    });

    test("each stop_reason is read as the stop it means", () async {
      const stops = {
        "end_turn": LlmStop.answered,
        "stop_sequence": LlmStop.answered,
        "tool_use": LlmStop.toolUse,
        "max_tokens": LlmStop.truncated,
        "refusal": LlmStop.refused,
        // A word the API does not have yet is an answer, as it was before.
        "something_new": LlmStop.answered,
      };
      for (final MapEntry(key: reason, value: stop) in stops.entries) {
        final chunks = await clientStreaming([
          {
            "type": "message_delta",
            "delta": {"stop_reason": reason},
          },
        ]).stream(const [], model: "claude-test").toList();
        expect(
          chunks.whereType<LlmCompletion>().single.stop,
          stop,
          reason: reason,
        );
      }
    });

    test("an error frame ends the stream with the reason", () async {
      final client = clientStreaming([
        {
          "type": "error",
          "error": {"type": "overloaded_error", "message": "overloaded"},
        },
      ]);

      expect(
        client.stream(const [], model: "claude-test").toList(),
        throwsA(
          isA<LlmException>().having((e) => e.message, "message", "overloaded"),
        ),
      );
    });
  });

  group("the request", () {
    test("the system prompt is a parameter, not a message", () async {
      await clientStreaming([]).stream(const [
        LlmMessage(role: LlmRole.system, text: "be careful"),
        LlmMessage(role: LlmRole.user, text: "hello"),
      ], model: "claude-test").toList();

      final body = sentBody();
      expect(body["system"], "be careful");
      expect((body["messages"] as List).single["role"], "user");
      expect(requests.single.headers["x-api-key"], "sk-ant-test");
      expect(requests.single.headers["anthropic-version"], "2023-06-01");
    });

    test(
      "a tool result rides inside the user turn that answers the call",
      () async {
        await clientStreaming([]).stream(const [
          LlmMessage(role: LlmRole.user, text: "list it"),
          LlmMessage(
            role: LlmRole.assistant,
            text: "on it",
            toolCalls: [
              LlmToolCall(
                id: "toolu_1",
                name: "bash",
                argumentsJson: '{"command":"ls"}',
              ),
            ],
          ),
          LlmMessage(role: LlmRole.tool, text: "a.txt", toolCallId: "toolu_1"),
        ], model: "claude-test").toList();

        final messages = sentBody()["messages"] as List;
        expect(messages.map((m) => m["role"]), ["user", "assistant", "user"]);
        final assistant = messages[1]["content"] as List;
        expect(assistant[0], {"type": "text", "text": "on it"});
        expect(assistant[1], {
          "type": "tool_use",
          "id": "toolu_1",
          "name": "bash",
          "input": {"command": "ls"},
        });
        expect((messages[2]["content"] as List).single, {
          "type": "tool_result",
          "tool_use_id": "toolu_1",
          "content": "a.txt",
        });
      },
    );

    test("two results for one turn are folded into a single answer", () async {
      await clientStreaming([]).stream(const [
        LlmMessage(role: LlmRole.user, text: "go"),
        LlmMessage(
          role: LlmRole.assistant,
          toolCalls: [
            LlmToolCall(id: "a", name: "bash", argumentsJson: "{}"),
            LlmToolCall(id: "b", name: "bash", argumentsJson: "{}"),
          ],
        ),
        LlmMessage(role: LlmRole.tool, text: "first", toolCallId: "a"),
        LlmMessage(role: LlmRole.tool, text: "second", toolCallId: "b"),
      ], model: "claude-test").toList();

      final messages = sentBody()["messages"] as List;
      expect(messages.map((m) => m["role"]), ["user", "assistant", "user"]);
      expect((messages[2]["content"] as List).map((b) => b["tool_use_id"]), [
        "a",
        "b",
      ]);
    });

    test(
      "thinking is handed back with its signature ahead of the reply",
      () async {
        await clientStreaming([]).stream(const [
          LlmMessage(role: LlmRole.user, text: "go"),
          LlmMessage(
            role: LlmRole.assistant,
            text: "here",
            reasoning: "thought about it",
            reasoningSignature: "sig-1",
          ),
        ], model: "claude-test").toList();

        final blocks = (sentBody()["messages"] as List)[1]["content"] as List;
        expect(blocks.first, {
          "type": "thinking",
          "thinking": "thought about it",
          "signature": "sig-1",
        });
      },
    );

    test(
      "thinking with no signature is left out rather than rejected",
      () async {
        await clientStreaming([]).stream(const [
          LlmMessage(role: LlmRole.user, text: "go"),
          LlmMessage(
            role: LlmRole.assistant,
            text: "here",
            reasoning: "unsigned",
          ),
        ], model: "claude-test").toList();

        final blocks = (sentBody()["messages"] as List)[1]["content"] as List;
        expect(blocks.map((b) => b["type"]), ["text"]);
      },
    );

    test(
      "effort buys a thinking budget, and drops the temperature with it",
      () async {
        await clientStreaming([])
            .stream(
              const [],
              model: "claude-test",
              temperature: 0.7,
              reasoningEffort: "low",
            )
            .toList();

        final body = sentBody();
        expect(body["thinking"], {"type": "enabled", "budget_tokens": 4096});
        // Anthropic pins the temperature at 1 once thinking is on, so sending
        // one alongside is a rejected request.
        expect(body.containsKey("temperature"), isFalse);
        expect(body["max_tokens"], greaterThan(4096));
      },
    );

    test("max_tokens is the cap, else the model's own limit, else the "
        "fallback", () async {
      Future<int> sent(LlmOutputLimit limit) async {
        await clientStreaming(
          [],
        ).stream(const [], model: "claude-test", outputLimit: limit).toList();
        return sentBody()["max_tokens"] as int;
      }

      expect(
        await sent(
          const LlmOutputLimit(length: 4096, capped: true, modelLimit: 128000),
        ),
        4096,
      );
      expect(
        await sent(const LlmOutputLimit(length: 4096, modelLimit: 128000)),
        128000,
      );
      expect(await sent(const LlmOutputLimit(length: 4096)), 4096);
      expect(
        await sent(const LlmOutputLimit()),
        AppSettings.defaultResponseLength,
      );
    });

    test("thinking fits inside a known limit and rides on top of a "
        "fallback", () {
      const budget = 16384;
      // The model's own limit is the whole; thinking is inside it.
      expect(
        AnthropicClient.budgetOf(
          const LlmOutputLimit(length: 8192, modelLimit: 128000),
          budget,
        ),
        (maxTokens: 128000, thinking: budget),
      );
      // A guess leaves the reply its own room, as the fixed 8192 did.
      expect(
        AnthropicClient.budgetOf(const LlmOutputLimit(length: 8192), budget),
        (maxTokens: 8192 + budget, thinking: budget),
      );
      // A cap below the budget shrinks the thinking to leave the reply room.
      expect(
        AnthropicClient.budgetOf(
          const LlmOutputLimit(length: 8192, capped: true),
          budget,
        ),
        (maxTokens: 8192, thinking: 8192 - 1024),
      );
      // Too small a cap for both: no thinking rather than a refused request.
      expect(
        AnthropicClient.budgetOf(
          const LlmOutputLimit(length: 1024, capped: true),
          budget,
        ),
        (maxTokens: 1024, thinking: null),
      );
    });

    test(
      "without effort there is no thinking and the temperature stands",
      () async {
        await clientStreaming(
          [],
        ).stream(const [], model: "claude-test", temperature: 0.7).toList();

        final body = sentBody();
        expect(body.containsKey("thinking"), isFalse);
        expect(body["temperature"], 0.7);
      },
    );

    test("an image goes as base64 with the type it was saved under", () async {
      await clientStreaming([]).stream([
        LlmMessage(
          role: LlmRole.user,
          text: "what is this?",
          attachments: [
            LlmAttachment(
              filename: "a.png",
              mimeType: "image/png",
              bytes: bytesOf([1, 2, 3]),
            ),
          ],
        ),
      ], model: "claude-test").toList();

      final blocks = (sentBody()["messages"] as List).single["content"] as List;
      expect(blocks[0], {"type": "text", "text": "what is this?"});
      expect(blocks[1]["type"], "image");
      expect(blocks[1]["source"]["media_type"], "image/png");
      expect(blocks[1]["source"]["data"], base64Encode(const [1, 2, 3]));
    });

    test("a PDF goes as a document block, ahead of the text", () async {
      await clientStreaming([]).stream([
        LlmMessage(
          role: LlmRole.user,
          text: "summarise",
          attachments: [
            LlmAttachment(
              filename: "a.pdf",
              mimeType: "application/pdf",
              bytes: bytesOf([1, 2]),
            ),
          ],
        ),
      ], model: "claude-test").toList();

      final blocks = (sentBody()["messages"] as List).single["content"] as List;
      expect(blocks[0], {
        "type": "document",
        "source": {
          "type": "base64",
          "media_type": "application/pdf",
          "data": base64Encode(const [1, 2]),
        },
      });
      expect(blocks[1], {"type": "text", "text": "summarise"});
    });
  });

  test("a tool result's images go inside it", () async {
    await clientStreaming([
      {"type": "message_stop"},
    ]).stream([
      const LlmMessage(role: LlmRole.user, text: "draw"),
      const LlmMessage(
        role: LlmRole.assistant,
        toolCalls: [
          LlmToolCall(id: "c1", name: "image_generation", argumentsJson: "{}"),
        ],
      ),
      LlmMessage(
        role: LlmRole.tool,
        toolCallId: "c1",
        text: "made",
        attachments: [
          LlmAttachment(
            filename: "a.png",
            mimeType: "image/png",
            bytes: Uint8List.fromList([1]),
          ),
        ],
      ),
    ], model: "claude-test").toList();

    final result =
        ((sentBody()["messages"] as List).last["content"] as List).single
            as Map;
    expect(result["type"], "tool_result");
    expect((result["content"] as List).map((b) => b["type"]), [
      "text",
      "image",
    ]);
  });

  test("a tool result's PDF goes inside it as a document", () async {
    await clientStreaming([
      {"type": "message_stop"},
    ]).stream([
      const LlmMessage(role: LlmRole.user, text: "read it"),
      const LlmMessage(
        role: LlmRole.assistant,
        toolCalls: [LlmToolCall(id: "c1", name: "read", argumentsJson: "{}")],
      ),
      LlmMessage(
        role: LlmRole.tool,
        toolCallId: "c1",
        text: "PDF a.pdf attached.",
        attachments: [
          LlmAttachment(
            filename: "a.pdf",
            mimeType: "application/pdf",
            bytes: Uint8List.fromList([1]),
          ),
        ],
      ),
    ], model: "claude-test").toList();

    final result =
        ((sentBody()["messages"] as List).last["content"] as List).single
            as Map;
    expect((result["content"] as List).map((b) => b["type"]), [
      "text",
      "document",
    ]);
  });
}
