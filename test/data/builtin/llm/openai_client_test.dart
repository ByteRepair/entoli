import "dart:convert";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

import "package:agent_chat/data/builtin/llm/gemini_client.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/openai_client.dart";

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
    test("a rate limit is worth trying again, a rejected key is not", () async {
      expect(
        clientRejecting(429, "slow down").stream(const [], model: "gpt-test").toList(),
        throwsA(isA<LlmException>()
            .having((e) => e.retryable, "retryable", isTrue)
            .having((e) => e.statusCode, "statusCode", 429)
            .having((e) => e.message, "message", "slow down")),
      );
      // 401 is policy, not a blip.
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

      // And carries temperature and effort when they are set.
      await clientStreaming(["[DONE]"])
          .stream(const [], model: "gpt-test", temperature: 0.4, reasoningEffort: "high")
          .toList();
      final with_ = sentBody();
      expect(with_["temperature"], 0.4);
      expect(with_["reasoning_effort"], "high");
    });

    test("the system messages at the head go as one", () async {
      await clientStreaming(["[DONE]"]).stream(const [
        LlmMessage(role: LlmRole.system, text: "be helpful"),
        LlmMessage(role: LlmRole.system, text: "work in /tmp"),
        LlmMessage(role: LlmRole.user, text: "hi"),
      ], model: "gpt-test").toList();

      final messages = sentBody()["messages"] as List;
      expect(messages, hasLength(2));
      expect(messages[0], {"role": "system", "content": "be helpful\n\nwork in /tmp"});
      expect(messages[1], {"role": "user", "content": "hi"});
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

  group("Gemini's thought signatures", () {
    test("are read off the call and handed back on it", () async {
      final chunks = await clientStreaming([
        delta({
          "tool_calls": [
            {
              "index": 0,
              "id": "c1",
              "function": {"name": "bash", "arguments": "{}"},
              "extra_content": {
                "google": {"thought_signature": "sig-1"},
              },
            },
          ],
        }),
        "[DONE]",
      ]).stream(const [], model: "gemini-test").toList();
      final call = chunks.whereType<LlmCompletion>().single.message.toolCalls.single;
      expect(call.signature, "sig-1");

      await clientStreaming(["[DONE]"]).stream([
        LlmMessage(role: LlmRole.assistant, toolCalls: [call]),
      ], model: "gemini-test").toList();
      final sent = (sentBody()["messages"] as List).single["tool_calls"][0];
      expect(sent["extra_content"], {
        "google": {"thought_signature": "sig-1"},
      });
    });

    test("an unsigned call is sent as it was to anyone but Gemini", () async {
      await clientStreaming(["[DONE]"]).stream(const [
        LlmMessage(
          role: LlmRole.assistant,
          toolCalls: [LlmToolCall(id: "c1", name: "bash", argumentsJson: "{}")],
        ),
      ], model: "gpt-test").toList();
      final sent = (sentBody()["messages"] as List).single["tool_calls"][0] as Map;
      expect(sent.containsKey("extra_content"), isFalse);
    });

    test("Gemini gets the placeholder on the first of an unsigned reply's calls", () async {
      requests = [];
      final client = GeminiClient(
        baseUrl: Uri.parse("https://generativelanguage.googleapis.com/v1beta/openai"),
        httpClient: MockClient.streaming((request, _) async {
          requests.add(request);
          return sseResponse(["[DONE]"]);
        }),
      );
      await client.stream(const [
        LlmMessage(role: LlmRole.assistant, toolCalls: [
          LlmToolCall(id: "c1", name: "bash", argumentsJson: "{}"),
          LlmToolCall(id: "c2", name: "bash", argumentsJson: "{}"),
        ]),
      ], model: "gemini-test").toList();
      final calls = (sentBody()["messages"] as List).single["tool_calls"] as List;
      expect(calls[0]["extra_content"]["google"]["thought_signature"],
          "skip_thought_signature_validator");
      expect((calls[1] as Map).containsKey("extra_content"), isFalse);
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

    test("a PDF goes as a file part, as a data URL", () async {
      await clientStreaming(["[DONE]"]).stream([
        LlmMessage(
          role: LlmRole.user,
          text: "have a look",
          attachments: [
            LlmAttachment(
              filename: "report.pdf",
              mimeType: "application/pdf",
              bytes: bytesOf([1, 2]),
            ),
          ],
        ),
      ], model: "gpt-test").toList();

      final content = (sentBody()["messages"] as List).single["content"] as List;
      expect(content[0], {"type": "text", "text": "have a look"});
      expect(content[1], {
        "type": "file",
        "file": {
          "filename": "report.pdf",
          "file_data": "data:application/pdf;base64,${base64Encode(const [1, 2])}",
        },
      });
    });

    test("anything else is named rather than sent", () async {
      await clientStreaming(["[DONE]"]).stream([
        LlmMessage(
          role: LlmRole.user,
          text: "have a look",
          attachments: [
            LlmAttachment(
              filename: "data.zip",
              mimeType: "application/zip",
              bytes: bytesOf([0]),
            ),
          ],
        ),
      ], model: "gpt-test").toList();

      final content = (sentBody()["messages"] as List).single["content"] as String;
      expect(content, contains("(attached: data.zip, application/zip)"));
    });
  });

  /// llama.cpp's own extension, and what lets a phone draw a prefill that takes
  /// minutes rather than a spinner that cannot be told apart from a hang.
  group("how far it has got through the prompt", () {
    test("is not asked for unless the endpoint is known to answer it", () async {
      final client = clientStreaming([delta({"content": "hi"}), "[DONE]"]);

      await client.stream(const [], model: "m").toList();

      // A hosted provider is entitled to reject a field it has never heard of,
      // and the strict ones do — so this must not go out by default.
      expect(sentBody().containsKey("return_progress"), isFalse);
    });

    test("is asked for where it was turned on", () async {
      requests = [];
      final client = OpenAiClient(
        baseUrl: Uri.parse("https://example.test/v1"),
        returnProgress: true,
        httpClient: MockClient.streaming((request, _) async {
          requests.add(request);
          return sseResponse([delta({"content": "hi"}), "[DONE]"]);
        }),
      );

      await client.stream(const [], model: "m").toList();

      expect(sentBody()["return_progress"], isTrue);
    });

    test("arrives as its own chunk, before there is anything to say", () async {
      final client = clientStreaming([
        {
          "prompt_progress": {"total": 2700, "cache": 0, "processed": 1350},
        },
        delta({"content": "hi"}),
        "[DONE]",
      ]);

      final chunks = await client.stream(const [], model: "m").toList();

      final progress = chunks.whereType<LlmPromptProgress>().single;
      expect(progress.processed, 1350);
      expect(progress.total, 2700);
      expect(progress.fraction, 0.5);
    });

    test("a frame with no choices on it is not dropped", () async {
      // It really does arrive with `choices` empty, so this has to be read
      // before the guard that skips a frame with nothing in it.
      final client = clientStreaming([
        {
          "choices": const [],
          "prompt_progress": {"total": 10, "cache": 8, "processed": 8},
        },
        "[DONE]",
      ]);

      final chunks = await client.stream(const [], model: "m").toList();

      expect(chunks.whereType<LlmPromptProgress>().single.cache, 8);
    });

    test("a prompt the server called empty has no fraction to report", () async {
      final client = clientStreaming([
        {
          "prompt_progress": {"total": 0, "cache": 0, "processed": 0},
        },
        "[DONE]",
      ]);

      final chunks = await client.stream(const [], model: "m").toList();

      // Null rather than a division by zero, and rather than a confident 100%.
      expect(chunks.whereType<LlmPromptProgress>().single.fraction, isNull);
    });
  });

  group("images", () {
    const png = "data:image/png;base64,iVBORw0K";

    test("an image a model streams back rides the completion", () async {
      final chunks = await clientStreaming([
        delta({"content": "Here it is"}),
        delta({
          "images": [
            {"type": "image_url", "image_url": {"url": png}},
            {"type": "image_url", "image_url": {"url": "https://not.inline/x.png"}},
          ],
        }),
        "[DONE]",
      ]).stream(const [], model: "img-test").toList();

      final image = chunks.whereType<LlmCompletion>().single.message.attachments.single;
      expect(image.mimeType, "image/png");
      expect(image.bytes, base64Decode("iVBORw0K"));
    });

    OpenAiClient clientAnswering(Object body) {
      requests = [];
      return OpenAiClient(
        baseUrl: Uri.parse("https://example.test/v1"),
        httpClient: MockClient.streaming((request, _) async {
          requests.add(request);
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), 200);
        }),
      );
    }

    test("speech is transcribed through the audio endpoint", () async {
      final text = await clientAnswering({"text": "hello"})
          .transcribe(Uint8List.fromList([1, 2]), model: "whisper-x");

      final sent = requests.single as http.MultipartRequest;
      expect(sent.url.path, "/v1/audio/transcriptions");
      expect(sent.fields["model"], "whisper-x");
      expect(sent.files.single.filename, "speech.wav");
      expect(text, "hello");
    });

    test("a sentence is spoken as WAV, with the voice only where named", () async {
      final client = clientAnswering({});
      await client.speak("hi", model: "tts-x");
      expect(requests.single.url.path, "/v1/audio/speech");
      expect(sentBody(), {"model": "tts-x", "input": "hi", "response_format": "wav"});

      await clientAnswering({}).speak("hi", model: "tts-x", voice: "alloy");
      expect(sentBody()["voice"], "alloy");
    });

    test("an OpenAI image model is asked through the Images API", () async {
      final images = await clientAnswering({
        "data": [
          {"b64_json": "iVBORw0K"},
        ],
      }).generateImage("a cat", model: "gpt-image-1");

      expect(requests.single.url.path, "/v1/images/generations");
      expect(sentBody(), {"model": "gpt-image-1", "prompt": "a cat"});
      expect(images.single.bytes, base64Decode("iVBORw0K"));
    });

    test("a tool result's images follow the results in a user message", () async {
      await clientStreaming(["[DONE]"]).stream([
        const LlmMessage(role: LlmRole.assistant, toolCalls: [
          LlmToolCall(id: "c1", name: "image_generation", argumentsJson: "{}"),
          LlmToolCall(id: "c2", name: "bash", argumentsJson: "{}"),
        ]),
        LlmMessage(role: LlmRole.tool, toolCallId: "c1", text: "made", attachments: [
          LlmAttachment(filename: "a.png", mimeType: "image/png", bytes: base64Decode("iVBORw0K")),
        ]),
        const LlmMessage(role: LlmRole.tool, toolCallId: "c2", text: "ok"),
      ], model: "gpt-test").toList();

      final sent = (sentBody()["messages"] as List).cast<Map<String, dynamic>>();
      expect(sent.map((m) => m["role"]), ["assistant", "tool", "tool", "user"]);
      expect(sent[1]["content"], "made");
      expect((sent.last["content"] as List).last["image_url"]["url"], png);
    });

    test("a tool result's PDF follows the results as a file part", () async {
      await clientStreaming(["[DONE]"]).stream([
        const LlmMessage(role: LlmRole.assistant, toolCalls: [
          LlmToolCall(id: "c1", name: "read", argumentsJson: "{}"),
        ]),
        LlmMessage(role: LlmRole.tool, toolCallId: "c1", text: "PDF a.pdf attached.", attachments: [
          LlmAttachment(filename: "a.pdf", mimeType: "application/pdf", bytes: Uint8List(1)),
        ]),
      ], model: "gpt-test").toList();

      final sent = (sentBody()["messages"] as List).cast<Map<String, dynamic>>();
      expect(sent.map((m) => m["role"]), ["assistant", "tool", "user"]);
      expect((sent.last["content"] as List).last["type"], "file");
    });

    test("a Gemini image model is asked natively, and its JPEG kept", () async {
      const jpeg = "/9j/4AAQSkZJRgABAQ==";
      requests = [];
      final images = await GeminiClient(
        baseUrl: Uri.parse("https://generativelanguage.googleapis.com/v1beta/openai"),
        apiKey: "g-key",
        httpClient: MockClient.streaming((request, _) async {
          requests.add(request);
          return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode({
                "candidates": [
                  {
                    "content": {
                      "parts": [
                        {"text": "here"},
                        {
                          "inlineData": {"mimeType": "image/jpeg", "data": jpeg},
                        },
                      ],
                    },
                  },
                ],
              }))),
              200);
        }),
      ).generateImage("a cat", model: "gemini-image", quality: "high");

      final sent = requests.single;
      expect(sent.url.path, "/v1beta/models/gemini-image:generateContent");
      expect(sent.headers["x-goog-api-key"], "g-key");
      expect(sentBody()["contents"][0]["parts"][0]["text"], "a cat");
      expect(images.single.mimeType, "image/jpeg");
      expect(images.single.filename, "image-0.jpeg");
    });

    test("quality is sent as the Images API names it", () async {
      final answer = {"data": const []};
      await clientAnswering(answer)
          .generateImage("a cat", model: "gpt-image-1", quality: "low");
      expect(sentBody()["quality"], "low");
      await clientAnswering(answer)
          .generateImage("a cat", model: "dall-e-3", quality: "high");
      expect(sentBody()["quality"], "hd");
    });

    test("any other model is asked for the image modality", () async {
      final images = await clientAnswering({
        "choices": [
          {
            "message": {
              "content": "",
              "images": [
                {"type": "image_url", "image_url": {"url": png}},
              ],
            },
          },
        ],
      }).generateImage("a cat", model: "google/gemini-2.5-flash-image");

      expect(requests.single.url.path, "/v1/chat/completions");
      expect(sentBody()["modalities"], ["image", "text"]);
      expect(images.single.mimeType, "image/png");
    });
  });

  group("Gemini", () {
    GeminiClient geminiRejecting(int status) => GeminiClient(
          baseUrl: Uri.parse("https://generativelanguage.googleapis.com/v1beta/openai"),
          httpClient: MockClient.streaming((_, _) async => errorResponse(status, {
                "error": {"message": "whatever Google says this week"},
              })),
        );

    test("a 404 says the model is retired, whatever Google's wording", () async {
      await expectLater(
        geminiRejecting(404).stream(const [], model: "gemini-2.5-flash").toList(),
        throwsA(isA<LlmException>()
            .having((e) => e.toString(), "text", GeminiClient.retired)
            .having((e) => e.retryable, "retryable", isFalse)),
      );
    });

    test("any other failure is left as it was", () async {
      await expectLater(
        geminiRejecting(429).stream(const [], model: "gemini-3.8-flash").toList(),
        throwsA(isA<LlmException>().having((e) => e.statusCode, "statusCode", 429)),
      );
    });
  });
}
