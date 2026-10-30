import "dart:async";

import "package:flutter/services.dart";
import "package:http/http.dart" as http;

import "../../domain/local_model.dart";
import "../../domain/llm_provider.dart";
import "../builtin/llm/llm_client.dart";
import "../builtin/llm/providers/provider.dart";
import "../model_host/host_connection.dart";
import "../model_host/model_host.dart";

// The ids live in the domain beside `localProviderId`, exported here for the
// tests and the pages that name the model.
export "../../domain/local_model.dart" show appleProviderId, appleModelId;

/// The Apple on-device model, reached through its own framework as an
/// ordinary provider.
///
/// There is no server: `SystemLanguageModel` is the OS's own, reached
/// through the Foundation Models framework (iOS 26 and later) behind a
/// method channel — `AppleFmChannel.swift`, beside `VoiceChannel.swift`. The
/// port surface is an [AppleFmProvider] carrying its own client, composed into
/// `modelProvidersProvider` beside the llama pool, so the registry, the pickers, a
/// chat's pinned model and every tool the agent has see a provider like any
/// other. None of the machine questions the pool answers (devices, threads,
/// context, KV caches) exists here, and the window the compaction reads is
/// answered by the model registry, not by this channel.
///
/// **Tool calls arrive decoded.** The framework runs the tool protocol's
/// own half, so there is no chat-template parser anywhere in this file —
/// the thing that made llama.cpp's server worth its process on Android. The
/// Swift tool reports its call over the channel and ends its generation
/// there: the loop stays the agent's, exactly as it is for every hosted
/// provider, because approvals, the recorder and the projections hang off
/// that ownership. The framework's own tool loop is therefore never let
/// near, whatever convenience that would promise.
///
/// One model turn per `stream`: the client composes the whole history into
/// the request, the Swift side seeds a fresh `LanguageModelSession` from it,
/// and nothing is held between calls. That is the parity the projection
/// enforces for every other provider — a rewind, a compaction or an edit is
/// just a different history, never hidden state — at the cost of the
/// framework's KV reuse, which Apple's own session management would have
/// wanted a held session for.
const appleChannel = MethodChannel("agent_chat/apple_fm");

/// The availability, as the handshake answered it. [reason] is the
/// framework's own, one of `os` (this OS predates the framework entirely),
/// `device-not-eligible`, `not-enabled`, `not-ready` (the model assets are
/// still being fetched) and `other`.
///
/// Where the endpoint rides in the pickers at all is the platform half's
/// answer, not this class's: a device that could never carry the model
/// composes no endpoint, while one that has the model *disabled* still
/// offers it — the wording below is then the one place that says why
/// nothing came back.
class AppleFmProbe {
  const AppleFmProbe(this.reason, {this.mlx = false});

  final String reason;

  /// Whether the build carries the MLX models' package and the OS can run
  /// one, which is what decides the platform's engine is `MlxEngine`. The
  /// handshake says so, because what a build links is the build's answer, the
  /// same way the llama backends are the server's.
  final bool mlx;

  LlmException get unavailable => switch (reason) {
    "not-enabled" => const LlmException(
      "Apple Intelligence is not enabled. It is a system setting, not "
      "this app's: set it in Settings, and the next turn reaches this "
      "model.",
    ),
    "not-ready" => const LlmException(
      "The Apple on-device model is not ready yet; the system is still "
      "fetching it.",
      retryable: true,
    ),
    _ => const LlmException("The Apple on-device model is unavailable."),
  };
}

/// The port: what the handshake said, and the provider composed from it.
class AppleFm {
  const AppleFm(this.probe);

  final AppleFmProbe probe;

  LlmProviderConfig get provider => LlmProviderConfig(
    id: appleProviderId,
    name: "Apple on-device",
    api: LlmApi.openai,
    // Empty, and it has to be: there is nothing here a URL could reach,
    // the endpoint carries its own client, and an empty string keeps the
    // registry's cache signature still. The shape rides out of habit
    // rather than need.
    baseUrl: "",
    defaultModelId: appleModelId,
  );

  LlmProvider get endpoint => AppleFmProvider(provider, probe);
}

class AppleFmProvider extends LlmProvider with KeyFree {
  const AppleFmProvider(super.config, this.probe);

  final AppleFmProbe probe;

  @override
  LlmClient client(String? apiKey) => AppleFmClient(probe);

  @override
  Future<List<String>> listModels(
    String? apiKey, {
    http.Client? httpClient,
  }) async => [appleModelId];
}

/// A model the Foundation Models framework runs, as a client: the Apple
/// system model ([AppleFmClient]) or an MLX model (`MlxEngine`'s). Both speak
/// the same channel and differ in [route], what the channel is told runs the
/// model, and in [channel], where its native half is — this process for the
/// system model, the model host for MLX. Nothing is held between calls, so
/// [close] is nothing and a rebuilt client costs nothing — the registry can
/// cache or drop this as it likes.
abstract class FoundationModelsClient implements LlmClient {
  FoundationModelsClient(this.channel);

  /// One counter for the whole process, across every client the registry
  /// ever built: a generation id must not mean two things to one channel.
  static var _generations = 0;

  final ModelChannel channel;

  /// What the model is called in an error, after "the": "Apple on-device
  /// model".
  String get label;

  /// The channel arguments naming what runs [model], once it can run: throws
  /// an [LlmException] where it never will.
  Future<Map<String, Object?>> route(String model);

  @override
  void close() {}

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    final target = await route(model);
    final generation = "fm${++_generations}";

    // The state the completion's message is assembled from — locals, not
    // fields: one client is the registry's one cache entry, and concurrent
    // streams of its own would have been one buffer each.
    final textSoFar = StringBuffer();
    final thought = StringBuffer();
    final calls = <LlmToolCall>[];

    // Registered before the request goes out, so a frame the platform sent
    // early cannot fall between the request and its listener.
    final events = StreamController<MethodCall>();
    final subscription = channel.calls
        .where((call) => (call.arguments as Map?)?["id"] == generation)
        .listen(events.add, onError: events.addError);
    var finished = false;
    try {
      await channel.invokeMethod("generate", {
        "id": generation,
        ...target,
        "instructions": joinedSystemText(messages),
        "history": _transcript(messages),
        // A trailing tool result is worded the way the history words one, or
        // the model reads it as something the user typed.
        "prompt": messages.last.role == LlmRole.tool
            ? _toolResultText(messages.last, _toolNames(messages))
            : _promptText(messages.last),
        "tools": [
          for (final tool in tools)
            {
              "name": tool.name,
              "description": tool.description,
              "schema": tool.schema,
            },
        ],
        "temperature": ?temperature,
      });

      await for (final call in events.stream) {
        switch (call.method) {
          case "text":
            final text = (call.arguments as Map?)?["text"] as String?;
            if (text != null && text.isNotEmpty) {
              textSoFar.write(text);
              yield LlmTextChunk(text);
            }
          case "reasoning":
            // A thinking model's trace, apart from its reply: on an MLX turn
            // with tools offered it is all that streams, the reply arriving
            // whole at the end.
            final text = (call.arguments as Map?)?["text"] as String?;
            if (text != null && text.isNotEmpty) {
              thought.write(text);
              yield LlmReasoningChunk(text);
            }
          case "toolCall":
            final args = call.arguments as Map?;
            calls.add(
              LlmToolCall(
                id: "c${calls.length}",
                name: args?["name"] as String? ?? "",
                argumentsJson: args?["arguments"] as String? ?? "{}",
              ),
            );
            // The handoff is the whole protocol here: the framework reports
            // one call and stops, so the reply is complete now. Waiting for a
            // `done` that may never come — a cancelled framework does not
            // send one — is how this stream became a hang.
            finished = true;
            yield LlmCompletion(
              message: LlmMessage(
                role: LlmRole.assistant,
                text: textSoFar.toString(),
                toolCalls: List.of(calls),
                reasoning: thought.isEmpty ? null : thought.toString(),
              ),
              finishReason: "tool_calls",
            );
            return;
          case "done":
            finished = true;
            final args = call.arguments as Map?;
            final input = (args?["inputTokens"] as num?)?.toInt();
            final output = (args?["outputTokens"] as num?)?.toInt();
            yield LlmCompletion(
              message: LlmMessage(
                role: LlmRole.assistant,
                text: textSoFar.toString(),
                reasoning: thought.isEmpty ? null : thought.toString(),
              ),
              finishReason: args?["finish"] as String? ?? "stop",
              // Real counts where the session keeps them (iOS 27 and
              // later); null where it does not, and the estimate path
              // stands in — the same answer a provider that reports
              // nothing gives.
              usage: input == null && output == null
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
            final args = call.arguments as Map?;
            throw _errorOf(
              label,
              args?["code"] as String? ?? "other",
              args?["message"] as String? ?? "",
            );
        }
      }
      throw LlmException("The $label never answered.", statusCode: 502);
    } on ModelHostGone {
      // Its process went mid-turn, and the next turn starts another: worth
      // the retry a dropped connection to a provider gets.
      finished = true;
      throw LlmException("The $label stopped.", retryable: true);
    } finally {
      // Unsubscribe first: a cancel arriving at the Swift half cannot race a
      // generation this client is still reading.
      await subscription.cancel();
      await events.close();
      if (!finished) {
        try {
          await channel.invokeMethod("cancel", {"id": generation});
        } catch (_) {
          // Best-effort by construction: an engine mid-teardown, or a test
          // host with nothing behind the channel. The Swift side's own
          // handoff cancellation is the other half of stopping a generation,
          // and the turn's stop has no second path to wait on.
        }
      }
    }
  }
}

/// The Apple system model, gated on its own availability.
class AppleFmClient extends FoundationModelsClient {
  /// The system model is the OS's own process already, so its channel is
  /// always this one's.
  AppleFmClient(this.probe) : super(PlatformModelChannel(appleChannel));

  final AppleFmProbe probe;

  @override
  String get label => "Apple on-device model";

  @override
  Future<Map<String, Object?>> route(String model) async {
    if (probe.reason != "available") throw probe.unavailable;
    return {"model": appleModelId};
  }
}

/// The user's words, with what rode with them. Text attachments are inlined;
/// anything else is named, because a model that cannot read it is better
/// told it exists than handed bytes — the same rule the wire shape carries.
String _promptText(LlmMessage message) {
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

/// The conversation before the prompt, as dialogue entries — everything but
/// the last message, which the caller composes as the prompt itself. A tool
/// call is worded onto its own assistant message and its answer as the
/// reader's — a two-party transcript has no third role, and the pairing is
/// the model's to read out of adjacency, which is where the loop left it.
List<Map<String, String>> _transcript(List<LlmMessage> messages) {
  final names = _toolNames(messages);
  final rest = messages.sublist(0, messages.length - 1);
  return [
    for (final message in rest)
      if (message.role != LlmRole.system)
        switch (message.role) {
          LlmRole.system => throw StateError("unreachable"),
          LlmRole.assistant when message.toolCalls.isNotEmpty => {
            "role": "assistant",
            "text": [
              if (message.text.isNotEmpty) message.text,
              for (final call in message.toolCalls)
                "[Called ${call.name} with ${call.argumentsJson}]",
            ].join("\n"),
          },
          LlmRole.assistant => {"role": "assistant", "text": message.text},
          LlmRole.user => {"role": "user", "text": _promptText(message)},
          LlmRole.tool => {
            "role": "user",
            "text": _toolResultText(message, names),
          },
        },
  ];
}

/// Each tool call's name by its id, for wording the results that answer them.
Map<String, String> _toolNames(List<LlmMessage> messages) => {
  for (final message in messages)
    for (final call in message.toolCalls) call.id: call.name,
};

String _toolResultText(LlmMessage message, Map<String, String> names) =>
    "[Result of the ${names[message.toolCallId] ?? "tool"} call:]\n"
    "${message.text}";

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
  _ => LlmException(
    message.isEmpty ? "The $label failed." : "The $label failed: $message",
  ),
};
