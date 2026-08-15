import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

import "package:agent_chat/data/miniswe/llm/llm_client.dart";
import "package:agent_chat/data/miniswe/llm/openai_client.dart";

import "sse.dart";

void main() {
  late List<http.BaseRequest> requests;

  /// A client whose endpoint replies with [frames] as an event stream.
  OpenAiClient clientStreaming(List<Object> frames) {
    requests = [];
    return OpenAiClient(
      baseUrl: Uri.parse("https://example.test/v1"),
      apiKey: "sk-test",
      httpClient: MockClient.streaming((request, _) async {
        requests.add(request);
        return sseResponse(frames);
      }),
    );
  }

  /// A client whose endpoint rejects the request outright.
  OpenAiClient clientRejecting(int status, String reason) => OpenAiClient(
        baseUrl: Uri.parse("https://example.test/v1"),
        httpClient: MockClient.streaming((_, _) async => errorResponse(status, {
              "error": {"message": reason},
            })),
      );

  Map<String, dynamic> sentBody() =>
      jsonDecode((requests.single as http.Request).body) as Map<String, dynamic>;

  Map<String, dynamic> delta(Map<String, dynamic> delta, {String? finishReason}) => {
        "choices": [
          {"index": 0, "delta": delta, "finish_reason": finishReason},
        ],
      };

  group("streaming", () {
    test("text arrives in pieces and is assembled once", () async {
      final chunks = await clientStreaming([
        delta({"content": "Hel"}),
        delta({"content": "lo"}),
        "[DONE]",
      ]).stream(const [], model: "gpt-test").toList();

      expect(chunks.whereType<LlmTextChunk>().map((c) => c.text), ["Hel", "lo"]);
      expect(chunks.whereType<LlmCompletion>().single.message.text, "Hello");
    });

    test("thinking is kept apart from the reply", () async {
      final chunks = await clientStreaming([
        delta({"reasoning_content": "hmm"}),
        delta({"reasoning": " and also"}),
        delta({"content": "answer"}),
        "[DONE]",
      ]).stream(const [], model: "gpt-test").toList();

      expect(chunks.whereType<LlmReasoningChunk>().map((c) => c.text), ["hmm", " and also"]);
      final message = chunks.whereType<LlmCompletion>().single.message;
      expect(message.reasoning, "hmm and also");
      expect(message.text, "answer");
    });

    test("a tool call spread over frames is put back together", () async {
      final chunks = await clientStreaming([
        delta({
          "tool_calls": [
            {
              "index": 0,
              "id": "call_1",
              "function": {"name": "bash", "arguments": "{\"comm"},
            },
          ],
        }),
        delta({
          "tool_calls": [
            {
              "index": 0,
              "function": {"arguments": "and\": \"ls\"}"},
            },
          ],
        }),
        delta({}, finishReason: "tool_calls"),
        "[DONE]",
      ]).stream(const [], model: "gpt-test").toList();

      final completion = chunks.whereType<LlmCompletion>().single;
      expect(completion.finishReason, "tool_calls");
      final call = completion.message.toolCalls.single;
      expect(call.id, "call_1");
      expect(call.name, "bash");
      expect(jsonDecode(call.argumentsJson), {"command": "ls"});
    });

    test("two calls in one reply keep their own arguments", () async {
      final chunks = await clientStreaming([
        delta({
          "tool_calls": [
            {
              "index": 0,
              "id": "a",
              "function": {"name": "bash", "arguments": "{\"command\":\"one\"}"},
            },
            {
              "index": 1,
              "id": "b",
              "function": {"name": "bash", "arguments": "{\"command\":\"two\"}"},
            },
          ],
        }),
        "[DONE]",
      ]).stream(const [], model: "gpt-test").toList();

      final calls = chunks.whereType<LlmCompletion>().single.message.toolCalls;
      expect(calls.map((c) => c.id), ["a", "b"]);
      expect(calls.map((c) => jsonDecode(c.argumentsJson)["command"]), ["one", "two"]);
    });

    test("a frame that is not JSON is skipped rather than fatal", () async {
      final chunks = await clientStreaming([
        "not json at all",
        delta({"content": "still here"}),
        "[DONE]",
      ]).stream(const [], model: "gpt-test").toList();

      expect(chunks.whereType<LlmTextChunk>().single.text, "still here");
    });

    test("an error announced mid-stream is thrown", () async {
      final client = clientStreaming([
        delta({"content": "part"}),
        {
          "error": {"message": "context length exceeded"},
        },
      ]);

      expect(
        client.stream(const [], model: "gpt-test").toList(),
        throwsA(isA<LlmException>()
            .having((e) => e.message, "message", contains("context length"))),
      );
    });
  });

  group("failures", () {
    test("a rate limit is worth trying again, and says why", () async {
      expect(
        clientRejecting(429, "slow down").stream(const [], model: "gpt-test").toList(),
        throwsA(isA<LlmException>()
            .having((e) => e.retryable, "retryable", isTrue)
            .having((e) => e.statusCode, "statusCode", 429)
            .having((e) => e.message, "message", "slow down")),
      );
    });

    test("a rejected key is not", () async {
      expect(
        clientRejecting(401, "invalid api key").stream(const [], model: "gpt-test").toList(),
        throwsA(isA<LlmException>().having((e) => e.retryable, "retryable", isFalse)),
      );
    });

    test("an endpoint that is not there at all is worth trying again", () async {
      final client = OpenAiClient(
        baseUrl: Uri.parse("https://example.test/v1"),
        httpClient: MockClient.streaming((_, _) => throw const ConnectionRefused()),
      );

      expect(
        client.stream(const [], model: "gpt-test").toList(),
        throwsA(isA<LlmException>().having((e) => e.retryable, "retryable", isTrue)),
      );
    });
  });

  group("the request", () {
    test("names the tool the model may call", () async {
      await clientStreaming(["[DONE]"]).stream(
        const [],
        model: "gpt-test",
        tools: const [
          LlmTool(name: "bash", description: "run it", schema: {"type": "object"}),
        ],
      ).toList();

      final body = sentBody();
      expect(body["stream"], isTrue);
      expect(body["tool_choice"], "auto");
      expect(body["tools"][0]["function"]["name"], "bash");
      expect(requests.single.headers["authorization"], "Bearer sk-test");
    });

    test("leaves out what was not asked for", () async {
      await clientStreaming(["[DONE]"]).stream(const [], model: "gpt-test").toList();

      final body = sentBody();
      expect(body.containsKey("temperature"), isFalse);
      expect(body.containsKey("reasoning_effort"), isFalse);
      expect(body.containsKey("tools"), isFalse);
    });

    test("carries temperature and effort when they are set", () async {
      await clientStreaming(["[DONE]"])
          .stream(const [], model: "gpt-test", temperature: 0.4, reasoningEffort: "high")
          .toList();

      expect(sentBody()["temperature"], 0.4);
      expect(sentBody()["reasoning_effort"], "high");
    });

    test("a tool result is addressed to the call it answers", () async {
      await clientStreaming(["[DONE]"]).stream(const [
        LlmMessage(role: LlmRole.system, text: "be helpful"),
        LlmMessage(
          role: LlmRole.assistant,
          text: "running it",
          toolCalls: [LlmToolCall(id: "c1", name: "bash", argumentsJson: "{}")],
        ),
        LlmMessage(role: LlmRole.tool, text: "output", toolCallId: "c1"),
      ], model: "gpt-test").toList();

      final messages = sentBody()["messages"] as List;
      expect(messages[0], {"role": "system", "content": "be helpful"});
      expect(messages[1]["tool_calls"][0]["id"], "c1");
      expect(messages[2], {"role": "tool", "tool_call_id": "c1", "content": "output"});
    });
  });

  group("attachments", () {
    test("a text file is inlined so the model can just read it", () async {
      await clientStreaming(["[DONE]"]).stream([
        LlmMessage(
          role: LlmRole.user,
          text: "what does this say?",
          attachments: [
            LlmAttachment(
              filename: "note.txt",
              mimeType: "text/plain",
              bytes: utf8.encode("the secret is 42"),
            ),
          ],
        ),
      ], model: "gpt-test").toList();

      final content = (sentBody()["messages"] as List).single["content"] as String;
      expect(content, contains("what does this say?"));
      expect(content, contains("note.txt"));
      expect(content, contains("the secret is 42"));
    });

    test("an image becomes a block of its own, as a data URL", () async {
      await clientStreaming(["[DONE]"]).stream([
        LlmMessage(
          role: LlmRole.user,
          text: "what is this?",
          attachments: [
            LlmAttachment(
              filename: "shot.png",
              mimeType: "image/png",
              bytes: bytesOf([1, 2, 3]),
            ),
          ],
        ),
      ], model: "gpt-test").toList();

      final content = (sentBody()["messages"] as List).single["content"] as List;
      expect(content[0], {"type": "text", "text": "what is this?"});
      expect(content[1]["type"], "image_url");
      expect(content[1]["image_url"]["url"], startsWith("data:image/png;base64,"));
    });

    test("anything else is named rather than sent", () async {
      await clientStreaming(["[DONE]"]).stream([
        LlmMessage(
          role: LlmRole.user,
          text: "have a look",
          attachments: [
            LlmAttachment(
              filename: "report.pdf",
              mimeType: "application/pdf",
              bytes: bytesOf([0]),
            ),
          ],
        ),
      ], model: "gpt-test").toList();

      final content = (sentBody()["messages"] as List).single["content"] as String;
      expect(content, contains("(attached: report.pdf, application/pdf)"));
    });
  });

  group("listing models", () {
    test("reads the ids the endpoint offers", () async {
      final client = OpenAiClient(
        baseUrl: Uri.parse("https://example.test/v1"),
        httpClient: MockClient((request) async {
          expect(request.url.path, "/v1/models");
          return http.Response(
            jsonEncode({
              "data": [
                {"id": "gpt-a"},
                {"id": "gpt-b"},
              ],
            }),
            200,
          );
        }),
      );

      expect(await client.listModels(), ["gpt-a", "gpt-b"]);
    });

    test("an endpoint that will not say contributes nothing", () async {
      final client = OpenAiClient(
        baseUrl: Uri.parse("https://example.test/v1"),
        httpClient: MockClient((_) async => http.Response("nope", 404)),
      );

      expect(await client.listModels(), isEmpty);
    });
  });
}
