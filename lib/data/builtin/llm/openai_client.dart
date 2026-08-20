import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "http_stream.dart";
import "llm_client.dart";

/// `/chat/completions` — OpenAI's shape, and everything that copied it:
/// OpenRouter, Groq, Together, ollama, LM Studio, vLLM. Only the base URL and
/// the key change.
class OpenAiClient implements LlmClient {
  OpenAiClient({
    required this.baseUrl,
    this.apiKey,
    this.returnProgress = false,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

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
        "messages": messages.map(_encodeMessage).toList(),
        "stream": true,
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
    String? finishReason;

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
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text.toString(),
        reasoning: reasoning.isEmpty ? null : reasoning.toString(),
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

  Map<String, dynamic> _encodeTool(LlmTool tool) => {
        "type": "function",
        "function": {
          "name": tool.name,
          "description": tool.description,
          "parameters": tool.schema,
        },
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
      for (final image in images)
        {
          "type": "image_url",
          "image_url": {"url": "data:${image.mimeType};base64,${image.base64}"},
        },
    ];
  }
}

class _PartialCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
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
