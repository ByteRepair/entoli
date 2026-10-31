import "dart:async";

import "package:flutter/services.dart";

import "../builtin/llm/llm_client.dart";
import "../model_host/host_connection.dart";
import "../model_host/model_host.dart";

/// One generation over a channel whose native half answers in frames —
/// `text`, `reasoning`, `toolCall`, `done`, `error`, each carrying the id it
/// was asked under — as a stream of [LlmChunk]s. The Apple system model and
/// the MLX models both answer this way, and both end with `done` or `error`:
/// the tool calls a reply made arrive before its `done`.
class ChannelGeneration {
  ChannelGeneration(this.channel, {required this.label});

  /// One counter for the whole process: a generation id must not mean two
  /// things to one channel.
  static var _generations = 0;

  final ModelChannel channel;

  /// What the model is called in an error, after "the".
  final String label;

  Stream<LlmChunk> run(String method, Map<String, Object?> arguments) async* {
    final generation = "fm${++_generations}";

    // The state the completion's message is assembled from.
    final textSoFar = StringBuffer();
    final thought = StringBuffer();
    final calls = <LlmToolCall>[];

    LlmCompletion completion(String finish, [LlmUsage? usage]) => LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: textSoFar.toString(),
        toolCalls: List.of(calls),
        reasoning: thought.isEmpty ? null : thought.toString(),
      ),
      finishReason: finish,
      usage: usage,
    );

    // Registered before the request goes out, so a frame the platform sent
    // early cannot fall between the request and its listener.
    final events = StreamController<MethodCall>();
    final subscription = channel.calls
        .where((call) => (call.arguments as Map?)?["id"] == generation)
        .listen(events.add, onError: events.addError);
    var finished = false;
    try {
      await channel.invokeMethod(method, {"id": generation, ...arguments});

      await for (final call in events.stream) {
        final args = call.arguments as Map?;
        switch (call.method) {
          case "text":
            final text = args?["text"] as String?;
            if (text != null && text.isNotEmpty) {
              textSoFar.write(text);
              yield LlmTextChunk(text);
            }
          case "reasoning":
            // A thinking model's trace, apart from its reply.
            final text = args?["text"] as String?;
            if (text != null && text.isNotEmpty) {
              thought.write(text);
              yield LlmReasoningChunk(text);
            }
          case "toolCall":
            calls.add(
              LlmToolCall(
                id: args?["callId"] as String? ?? "c${calls.length}",
                name: args?["name"] as String? ?? "",
                argumentsJson: args?["arguments"] as String? ?? "{}",
              ),
            );
          case "done":
            finished = true;
            final input = (args?["inputTokens"] as num?)?.toInt();
            final output = (args?["outputTokens"] as num?)?.toInt();
            yield completion(
              calls.isEmpty
                  ? (args?["finish"] as String?) ?? "stop"
                  : "tool_calls",
              // Real counts where the native half keeps them; null where it
              // does not, and the estimate path stands in — the same answer a
              // provider that reports nothing gives.
              input == null && output == null
                  ? null
                  : LlmUsage(
                      inputTokens: input ?? 0,
                      outputTokens: output ?? 0,
                      cacheReadTokens:
                          (args?["cachedTokens"] as num?)?.toInt() ?? 0,
                    ),
            );
            return;
          case "error":
            throw _errorOf(
              label,
              args?["code"] as String? ?? "other",
              args?["message"] as String? ?? "",
            );
        }
      }
      throw LlmException("The $label never answered.", statusCode: 502);
    } on ModelProcessGone {
      // Its process went mid-turn, and the next turn starts another: worth
      // the retry a dropped connection to a provider gets.
      finished = true;
      throw LlmException("The $label stopped.", retryable: true);
    } finally {
      // Unsubscribe first: a cancel arriving at the native half cannot race a
      // generation this is still reading.
      await subscription.cancel();
      await events.close();
      if (!finished) {
        try {
          await channel.invokeMethod("cancel", {"id": generation});
        } catch (_) {
          // Best-effort by construction: an engine mid-teardown, or a test
          // host with nothing behind the channel.
        }
      }
    }
  }
}

/// A message's words, with what rode with them, for a model that reads text
/// alone. Text attachments are inlined; anything else is named, because a
/// model that cannot read it is better told it exists than handed bytes.
String channelText(LlmMessage message) {
  final text = StringBuffer(message.text);
  for (final attachment in message.attachments) {
    if (attachment.isText) {
      text.writeln("\n${attachment.filename}:\n${attachment.asText}");
    } else {
      text.writeln(
        "\n[Attached file, not readable by this model: ${attachment.filename}]",
      );
    }
  }
  return text.toString().trim();
}

/// A tool as every native half reads one.
Map<String, Object?> channelTool(LlmTool tool) => {
  "name": tool.name,
  "description": tool.description,
  "schema": tool.schema,
};

/// The framework's failures, in the words the agent's retry machinery acts
/// on. `context` is deliberately not retryable: the same oversized request
/// re-sent is the same refusal, and the turn's honest answer is the wording
/// — the compaction ladder, which bounds its own asks and halves on any
/// error, is what recovers the session.
LlmException _errorOf(
  String label,
  String code,
  String message,
) => switch (code) {
  "context" => LlmException(
    "The conversation has outgrown the $label's context window. Compact "
    "the chat, or lower Total Context under Settings > LLMs.",
  ),
  "guardrail" => LlmException("The $label's guardrails refused this request."),
  "rate-limit" => LlmException("The $label is rate limited.", retryable: true),
  "assets" => LlmException(
    "The $label's assets are not ready; the system is still fetching them.",
    retryable: true,
  ),
  "language" => LlmException(
    "The $label does not support this conversation's language.",
  ),
  "resources" => LlmException("The $label ran short of device resources."),
  // Let go of from the settings page mid-reply: the reply ends there, and a
  // retry would only load it again.
  "unloaded" => LlmException("The $label was unloaded."),
  _ => LlmException(
    message.isEmpty ? "The $label failed." : "The $label failed: $message",
  ),
};
