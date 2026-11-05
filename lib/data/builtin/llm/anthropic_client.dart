import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "../../../core/tls.dart";

import "http_stream.dart";
import "llm_client.dart";
import "openai_client.dart" show inlineText;

/// Anthropic's `/messages`. Not reachable through the OpenAI-compatible client:
/// the system prompt is a parameter rather than a message, tool results ride
/// inside user turns, and thinking has to be handed back the way it came.
class AnthropicClient implements LlmClient {
  AnthropicClient({required this.baseUrl, this.apiKey, http.Client? httpClient})
    : _http = httpClient ?? tlsClient();

  final Uri baseUrl;
  final String? apiKey;
  final http.Client _http;

  static const _version = "2023-06-01";

  /// Room for the reply itself, on top of any thinking budget.
  static const _maxTokens = 8192;

  /// How much of the budget each effort buys. Anthropic takes a token count
  /// where the OpenAI shape takes a word, so the words are mapped onto counts.
  static const _thinkingBudget = {
    "minimal": 1024,
    "low": 4096,
    "medium": 8192,
    "high": 16384,
  };

  Map<String, String> get _auth => authOf(apiKey);

  static Map<String, String> authOf(String? apiKey) => {
    "anthropic-version": _version,
    if (apiKey != null && apiKey.isNotEmpty) "x-api-key": apiKey,
  };

  Map<String, String> get _headers => {
    "content-type": "application/json",
    "accept": "text/event-stream",
    ..._auth,
  };

  @override
  void close() => _http.close();

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    final budget = reasoningEffort == null
        ? null
        : _thinkingBudget[reasoningEffort] ?? 8192;
    final system = joinedSystemText(messages);

    final response = await postStream(
      _http,
      under(baseUrl, "messages"),
      headers: _headers,
      body: {
        "model": model,
        "max_tokens": budget == null ? _maxTokens : budget + _maxTokens,
        if (system.isNotEmpty) "system": system,
        "messages": _encodeMessages(messages),
        if (tools.isNotEmpty)
          "tools": [
            for (final tool in tools)
              {
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.schema,
              },
          ],
        "stream": true,
        // Thinking pins the temperature at 1, so the two are never sent together.
        if (budget != null)
          "thinking": {"type": "enabled", "budget_tokens": budget},
        if (budget == null && temperature != null) "temperature": temperature,
      },
    );

    final reader = AnthropicEventReader();
    await for (final payload in decodeSse(response.stream)) {
      final Map<String, dynamic> event;
      try {
        event = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      yield* Stream.fromIterable(reader.read(event));
    }
    yield reader.completion();
  }

  /// Tool results are user turns here, and a turn holding tool_use blocks must
  /// be answered by exactly one turn holding all their results — so consecutive
  /// messages of the same side are folded into one.
  List<Map<String, dynamic>> _encodeMessages(List<LlmMessage> messages) {
    final encoded = <Map<String, dynamic>>[];
    for (final message in messages) {
      if (message.role == LlmRole.system) continue;
      final role = message.role == LlmRole.assistant ? "assistant" : "user";
      final blocks = message.role == LlmRole.assistant
          ? _assistantBlocks(message)
          : userBlocks(message);
      if (blocks.isEmpty) continue;
      if (encoded.isNotEmpty && encoded.last["role"] == role) {
        (encoded.last["content"] as List).addAll(blocks);
      } else {
        encoded.add({"role": role, "content": blocks});
      }
    }
    return encoded;
  }

  List<Map<String, dynamic>> _assistantBlocks(LlmMessage message) => [
    // Thinking comes first and keeps its signature: with thinking enabled,
    // a tool-use turn that comes back without it is rejected.
    if (message.reasoning != null && message.reasoningSignature != null)
      {
        "type": "thinking",
        "thinking": message.reasoning,
        "signature": message.reasoningSignature,
      },
    if (message.text.isNotEmpty) {"type": "text", "text": message.text},
    for (final call in message.toolCalls)
      {
        "type": "tool_use",
        "id": call.id,
        "name": call.name,
        "input": _decodeArguments(call.argumentsJson),
      },
  ];

  /// [message], a user or tool turn, as the content blocks Anthropic takes.
  /// Claude CLI's stream-json input carries the same blocks.
  static List<Map<String, dynamic>> userBlocks(LlmMessage message) {
    if (message.role == LlmRole.tool) {
      final files = message.attachments.where((a) => a.isBlock);
      return [
        {
          "type": "tool_result",
          "tool_use_id": message.toolCallId ?? "",
          "content": files.isEmpty
              ? message.text
              : [
                  {"type": "text", "text": message.text},
                  ...files.map(_block),
                ],
        },
      ];
    }
    final text = inlineText(message);
    return [
      // Documents ahead of the text that asks about them, as Anthropic
      // recommends; images after it, where they have always gone.
      ...message.attachments.where((a) => a.isPdf).map(_block),
      if (text.isNotEmpty) {"type": "text", "text": text},
      ...message.attachments.where((a) => a.isImage).map(_block),
    ];
  }

  static Map<String, dynamic> _block(LlmAttachment file) => {
    "type": file.isPdf ? "document" : "image",
    "source": {
      "type": "base64",
      "media_type": file.mimeType,
      "data": file.base64,
    },
  };

  /// A truncated tool call leaves half a JSON object behind. Sending it back as
  /// an empty input keeps the turn replayable; the model sees its own mistake
  /// in the result.
  Map<String, dynamic> _decodeArguments(String json) {
    try {
      final decoded = jsonDecode(json.isEmpty ? "{}" : json);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }
}

/// Anthropic's stream events folded into chunks and, at the end, the whole
/// reply. Its own class because Claude CLI's partial messages are these same
/// events, one JSON line each rather than one SSE frame each.
class AnthropicEventReader {
  final _blocks = <int, _Block>{};
  String? _stopReason;
  int? _inputTokens, _cacheRead, _cacheWrite, _outputTokens;

  /// What the stop said, once `message_delta` has said it.
  String? get stopReason => _stopReason;

  // The usage fields accumulate across the frames that carry them: a frame
  // naming a field keeps what an earlier one said about the rest.
  void _readUsage(Map<String, dynamic>? usage) {
    if (usage == null) return;
    _inputTokens = (usage["input_tokens"] as num?)?.toInt() ?? _inputTokens;
    _cacheRead =
        (usage["cache_read_input_tokens"] as num?)?.toInt() ?? _cacheRead;
    _cacheWrite =
        (usage["cache_creation_input_tokens"] as num?)?.toInt() ?? _cacheWrite;
    _outputTokens = (usage["output_tokens"] as num?)?.toInt() ?? _outputTokens;
  }

  /// The chunks [event] says. Throws an [LlmException] for an `error` event.
  Iterable<LlmChunk> read(Map<String, dynamic> event) sync* {
    final index = (event["index"] as num?)?.toInt() ?? 0;

    switch (event["type"]) {
      case "error":
        final error = event["error"];
        throw LlmException(
          error is Map ? "${error["message"] ?? error}" : "$error",
        );

      case "content_block_start":
        final block =
            event["content_block"] as Map<String, dynamic>? ?? const {};
        _blocks[index] = _Block(
          type: block["type"] as String? ?? "text",
          id: block["id"] as String?,
          name: block["name"] as String?,
        );
        final text = block["text"];
        if (text is String && text.isNotEmpty) {
          _blocks[index]!.body.write(text);
          yield LlmTextChunk(text);
        }

      case "content_block_delta":
        final delta = event["delta"] as Map<String, dynamic>? ?? const {};
        final block = _blocks.putIfAbsent(index, () => _Block(type: "text"));
        switch (delta["type"]) {
          case "text_delta":
            final text = delta["text"] as String? ?? "";
            block.body.write(text);
            if (text.isNotEmpty) yield LlmTextChunk(text);
          case "thinking_delta":
            final text = delta["thinking"] as String? ?? "";
            block.body.write(text);
            if (text.isNotEmpty) yield LlmReasoningChunk(text);
          case "signature_delta":
            block.signature =
                (block.signature ?? "") + (delta["signature"] as String? ?? "");
          case "input_json_delta":
            block.body.write(delta["partial_json"] as String? ?? "");
        }

      case "content_block_stop":
        // The signature is complete here, which is still before the reply
        // starts — so the thinking block can be closed holding it.
        final block = _blocks[index];
        if (block != null &&
            block.type == "thinking" &&
            block.signature != null) {
          yield LlmReasoningSignature(block.signature!);
        }

      case "message_start":
        // The usage object arrives here and again — larger — on
        // message_delta; both are read, the latter winning.
        _readUsage(
          (event["message"] as Map<String, dynamic>?)?["usage"]
              as Map<String, dynamic>?,
        );

      case "message_delta":
        final delta = event["delta"] as Map<String, dynamic>? ?? const {};
        _stopReason = delta["stop_reason"] as String? ?? _stopReason;
        _readUsage(event["usage"] as Map<String, dynamic>?);
    }
  }

  /// The reply the events so far make up.
  LlmCompletion completion() {
    final ordered = _blocks.keys.toList()..sort();
    final text = StringBuffer();
    final reasoning = StringBuffer();
    String? signature;
    final calls = <LlmToolCall>[];
    for (final index in ordered) {
      final block = _blocks[index]!;
      switch (block.type) {
        case "text":
          text.write(block.body);
        case "thinking":
          reasoning.write(block.body);
          signature ??= block.signature;
        case "tool_use":
          calls.add(
            LlmToolCall(
              id: block.id ?? "toolu_$index",
              name: block.name ?? "",
              // An empty input streams no deltas at all, so the buffer is bare.
              argumentsJson: block.body.isEmpty ? "{}" : block.body.toString(),
            ),
          );
      }
    }

    return LlmCompletion(
      // `max_tokens` is what the OpenAI shape calls `length`; the agent reads
      // one name for "it was cut off before it could call a tool".
      finishReason: _stopReason == "max_tokens" ? "length" : _stopReason,
      usage: _inputTokens == null && _outputTokens == null
          ? null
          : LlmUsage(
              inputTokens: _inputTokens ?? 0,
              outputTokens: _outputTokens ?? 0,
              cacheReadTokens: _cacheRead ?? 0,
              cacheWriteTokens: _cacheWrite ?? 0,
            ),
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text.toString(),
        reasoning: reasoning.isEmpty ? null : reasoning.toString(),
        reasoningSignature: signature,
        toolCalls: calls,
      ),
    );
  }
}

class _Block {
  _Block({required this.type, this.id, this.name});

  final String type;
  final String? id;
  final String? name;
  final StringBuffer body = StringBuffer();
  String? signature;
}
