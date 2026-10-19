import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "../../../core/tls.dart";

import "http_stream.dart";
import "llm_client.dart";

/// `/chat/completions` — OpenAI's shape, and everything that copied it:
/// OpenRouter, Groq, Together, ollama, LM Studio, vLLM. The base URL and the
/// key are the whole of what differs between them; [returnProgress] is the one
/// knob that is not about a provider but about llama.cpp in particular.
class OpenAiClient implements LlmClient {
  OpenAiClient({
    required this.baseUrl,
    this.apiKey,
    this.returnProgress = false,
    http.Client? httpClient,
  }) : _http = httpClient ?? tlsClient();

  final Uri baseUrl;
  final String? apiKey;

  /// Ask for `prompt_progress` frames. llama.cpp's own extension, so it is off
  /// unless the endpoint is known to be one — a hosted provider is entitled to
  /// reject a field it has never heard of, and the strict ones do.
  final bool returnProgress;

  final http.Client _http;

  Map<String, String> get _auth =>
      {if (apiKey != null && apiKey!.isNotEmpty) "authorization": "Bearer $apiKey"};

  Map<String, String> get _headers => {
        "content-type": "application/json",
        "accept": "text/event-stream",
        ..._auth,
      };

  @override
  void close() => _http.close();

  @override
  Future<List<String>> listModels() =>
      listModelIds(_http, under(baseUrl, "models"), headers: _auth);

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    final response = await postStream(
      _http,
      under(baseUrl, "chat/completions"),
      headers: _headers,
      body: {
        "model": model,
        "messages": _encodeAll(mergeLeadingSystem(messages)),
        "stream": true,
        // Ask for the usage object on the final frame: OpenAI's streaming
        // shape sends it only when asked, and the auto-compact threshold
        // reads it. A gateway that drops the field degrades to no usage,
        // which the parse below already answers.
        "stream_options": {"include_usage": true},
        if (returnProgress) "return_progress": true,
        if (tools.isNotEmpty) ...{
          "tools": tools.map(_encodeTool).toList(),
          "tool_choice": "auto",
        },
        "temperature": ?temperature,
        "reasoning_effort": ?reasoningEffort,
      },
    );

    final text = StringBuffer();
    final reasoning = StringBuffer();
    final calls = <int, _PartialCall>{};
    final images = <LlmAttachment>[];
    String? finishReason;
    LlmUsage? usage;

    await for (final payload in decodeSse(response.stream)) {
      if (payload == "[DONE]") break;
      final Map<String, dynamic> event;
      try {
        event = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      // Some gateways report a mid-stream failure as a frame rather than a
      // status code, which would otherwise look like an empty reply.
      final error = event["error"];
      if (error != null) {
        throw LlmException(error is Map ? "${error["message"] ?? error}" : "$error");
      }

      // Its own frame rather than something on a delta: it arrives while the
      // prompt is still being read, so there are no choices on it at all and
      // the check below would drop it.
      final progress = event["prompt_progress"];
      if (progress is Map<String, dynamic>) {
        yield LlmPromptProgress(
          processed: (progress["processed"] as num?)?.toInt() ?? 0,
          total: (progress["total"] as num?)?.toInt() ?? 0,
          cache: (progress["cache"] as num?)?.toInt() ?? 0,
        );
      }

      final choices = event["choices"];
      // The usage object rides the final frame, often with `choices` empty,
      // so it is read before the guard that skips such a frame.
      final rawUsage = event["usage"];
      if (rawUsage is Map<String, dynamic>) {
        final promptTokens = (rawUsage["prompt_tokens"] as num?)?.toInt();
        final completionTokens = (rawUsage["completion_tokens"] as num?)?.toInt();
        if (promptTokens != null || completionTokens != null) {
          final details = rawUsage["prompt_tokens_details"] as Map<String, dynamic>?;
          usage = LlmUsage(
            inputTokens: promptTokens ?? 0,
            outputTokens: completionTokens ?? 0,
            cacheReadTokens: (details?["cached_tokens"] as num?)?.toInt() ?? 0,
          );
        }
      }
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;
      finishReason = choice["finish_reason"] as String? ?? finishReason;

      final delta = choice["delta"] as Map<String, dynamic>?;
      if (delta == null) continue;

      final content = delta["content"];
      if (content is String && content.isNotEmpty) {
        text.write(content);
        yield LlmTextChunk(content);
      }

      // `reasoning_content` is DeepSeek's and ollama's, `reasoning` is
      // OpenRouter's. Neither is in the OpenAI spec, so both are checked.
      final thought = delta["reasoning_content"] ?? delta["reasoning"];
      if (thought is String && thought.isNotEmpty) {
        reasoning.write(thought);
        yield LlmReasoningChunk(thought);
      }

      images.addAll(imagesIn(delta["images"], start: images.length));

      final toolCalls = delta["tool_calls"];
      if (toolCalls is List) {
        for (final raw in toolCalls) {
          if (raw is! Map<String, dynamic>) continue;
          final index = (raw["index"] as num?)?.toInt() ?? 0;
          final call = calls.putIfAbsent(index, _PartialCall.new);
          if (raw["id"] is String) call.id = raw["id"] as String;
          final function = raw["function"] as Map<String, dynamic>?;
          if (function == null) continue;
          if (function["name"] is String) call.name = function["name"] as String;
          // Arguments stream a character at a time; only the whole of it parses.
          if (function["arguments"] is String) {
            call.arguments.write(function["arguments"] as String);
          }
        }
      }
    }

    yield LlmCompletion(
      finishReason: finishReason,
      usage: usage,
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text.toString(),
        reasoning: reasoning.isEmpty ? null : reasoning.toString(),
        attachments: images,
        toolCalls: [
          for (final index in calls.keys.toList()..sort())
            LlmToolCall(
              id: calls[index]!.id ?? "call_$index",
              name: calls[index]!.name ?? "",
              argumentsJson: calls[index]!.arguments.toString(),
            ),
        ],
      ),
    );
  }

  /// One image from [prompt]. OpenAI's own image models answer only the
  /// Images API; everything else that makes images through this shape
  /// (OpenRouter's) answers `/chat/completions` asked for the image modality.
  ///
  /// [quality] is `low`, `medium` or `high`, null for the provider's default.
  /// Only the Images API takes one; the chat shape has no such field.
  Future<List<LlmAttachment>> generateImage(String prompt,
      {required String model, String? quality}) async {
    final dallE = model.startsWith("dall-e");
    final imagesApi = model.startsWith("gpt-image") || dallE;
    final response = await postStream(
      _http,
      under(baseUrl, imagesApi ? "images/generations" : "chat/completions"),
      headers: {"content-type": "application/json", ..._auth},
      body: imagesApi
          ? {
              "model": model,
              "prompt": prompt,
              // gpt-image always answers base64 and rejects the field.
              if (dallE) "response_format": "b64_json",
              // DALL·E has two grades rather than three.
              if (quality != null)
                "quality": dallE ? (quality == "high" ? "hd" : "standard") : quality,
            }
          : {
              "model": model,
              "messages": [
                {"role": "user", "content": prompt},
              ],
              "modalities": ["image", "text"],
            },
    );
    final json = jsonDecode(await response.stream.bytesToString());
    if (json is! Map<String, dynamic>) return const [];
    if (imagesApi) {
      final data = json["data"];
      return [
        if (data is List)
          for (final (i, item) in data.indexed)
            if (item is Map && item["b64_json"] is String)
              LlmAttachment(
                filename: "image-$i.png",
                mimeType: "image/png",
                bytes: base64Decode(item["b64_json"] as String),
              ),
      ];
    }
    final choices = json["choices"];
    if (choices is! List || choices.isEmpty) return const [];
    final message = (choices.first as Map)["message"];
    return message is Map ? imagesIn(message["images"]) : const [];
  }

  Map<String, dynamic> _encodeTool(LlmTool tool) => {
        "type": "function",
        "function": {
          "name": tool.name,
          "description": tool.description,
          "parameters": tool.schema,
        },
      };

  /// A tool message takes text alone, so the images on a run of results go
  /// in one user message straight after it.
  List<Map<String, dynamic>> _encodeAll(List<LlmMessage> messages) {
    final out = <Map<String, dynamic>>[];
    final images = <LlmAttachment>[];
    for (final (i, message) in messages.indexed) {
      out.add(_encodeMessage(message));
      if (message.role == LlmRole.tool) {
        images.addAll(message.attachments.where((a) => a.isImage));
      }
      final runEnds = i + 1 == messages.length || messages[i + 1].role != LlmRole.tool;
      if (images.isNotEmpty && runEnds) {
        out.add({
          "role": "user",
          "content": [
            {"type": "text", "text": "The images the tool results above returned."},
            ...images.map(_imageUrl),
          ],
        });
        images.clear();
      }
    }
    return out;
  }

  Map<String, dynamic> _imageUrl(LlmAttachment image) => {
        "type": "image_url",
        "image_url": {"url": "data:${image.mimeType};base64,${image.base64}"},
      };

  Map<String, dynamic> _encodeMessage(LlmMessage message) {
    switch (message.role) {
      case LlmRole.tool:
        return {
          "role": "tool",
          "tool_call_id": message.toolCallId ?? "",
          "content": message.text,
        };
      case LlmRole.assistant:
        return {
          "role": "assistant",
          "content": message.text,
          if (message.toolCalls.isNotEmpty)
            "tool_calls": [
              for (final call in message.toolCalls)
                {
                  "id": call.id,
                  "type": "function",
                  "function": {"name": call.name, "arguments": call.argumentsJson},
                },
            ],
        };
      case LlmRole.system:
      case LlmRole.user:
        return {
          "role": message.role.name,
          "content": _encodeContent(message),
        };
    }
  }

  /// A plain string unless there is an image to send: the array form is
  /// accepted by fewer of the compatible servers, so it is only used when it
  /// has to be.
  Object _encodeContent(LlmMessage message) {
    final text = inlineText(message);
    final images = message.attachments.where((a) => a.isImage).toList();
    if (images.isEmpty) return text;
    return [
      if (text.isNotEmpty) {"type": "text", "text": text},
      ...images.map(_imageUrl),
    ];
  }
}

/// OpenRouter's `images`, on a message or a streamed delta: a list of
/// `{"type": "image_url", "image_url": {"url": "data:..."}}`. Not in the OpenAI
/// spec, so anything that is not a data URL is skipped rather than fetched.
/// [start] numbers the names on from the images a stream already had.
List<LlmAttachment> imagesIn(Object? images, {int start = 0}) {
  if (images is! List) return const [];
  final out = <LlmAttachment>[];
  for (final image in images) {
    final ref = image is Map ? image["image_url"] : null;
    final url = ref is Map ? ref["url"] : null;
    if (url is! String || !url.startsWith("data:")) continue;
    try {
      final data = UriData.parse(url);
      // `image/svg+xml` is an `.svg`.
      final ext = data.mimeType.split("/").last.split("+").first;
      out.add(LlmAttachment(
        filename: "image-${start + out.length}.$ext",
        mimeType: data.mimeType,
        bytes: data.contentAsBytes(),
      ));
    } on FormatException {
      continue;
    }
  }
  return out;
}

class _PartialCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

/// The system messages at the head of a request as one message.
///
/// A chat template renders `messages[0]` as the system block and nothing else:
/// Qwen3.5's raises `System message must be at the beginning.` on the second,
/// and llama.cpp's fallback for a template with no system role at all folds away
/// only the first. The agent sends two — the body every chat shares and the
/// turn's own — so on-device, and on any other server that renders a template,
/// the second one is fatal.
///
/// A blank line between them, which leaves the body a byte prefix of the merged
/// text and so still a token prefix of the rendered prompt: the warmed KV is
/// found the way it was. Done here rather than where the two are built because
/// `kvPrefixKeys` hashes per message and the body's own key is the shortest of
/// them — merged any earlier, the prefill would warm a prefix no turn looks for.
List<LlmMessage> mergeLeadingSystem(List<LlmMessage> messages) {
  final head = messages.takeWhile((m) => m.role == LlmRole.system).toList();
  if (head.length < 2) return messages;
  return [
    LlmMessage(
      role: LlmRole.system,
      text: head.map((m) => m.text).where((t) => t.isNotEmpty).join("\n\n"),
      attachments: [for (final m in head) ...m.attachments],
    ),
    ...messages.skip(head.length),
  ];
}

/// The message's text with its non-image attachments folded in. A text file is
/// worth reading inline; anything else is named, so the model knows to open it
/// off disk rather than wait for bytes that will not come.
String inlineText(LlmMessage message) {
  // The common case by far — every system message and every plain prompt — so
  // it does not pay for a buffer that would copy it back unchanged.
  if (message.attachments.isEmpty) return message.text;
  final buffer = StringBuffer(message.text);
  for (final attachment in message.attachments) {
    if (attachment.isImage) continue;
    buffer.write("\n\n");
    if (attachment.isText) {
      buffer.writeln("--- ${attachment.filename} ---");
      buffer.writeln(attachment.asText);
      buffer.write("--- end of ${attachment.filename} ---");
    } else {
      buffer.write("(attached: ${attachment.filename}, ${attachment.mimeType})");
    }
  }
  return buffer.toString();
}
