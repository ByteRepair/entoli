import "package:flutter/services.dart";
import "package:http/http.dart" as http;

import "../../domain/local_model.dart";
import "../../domain/llm_provider.dart";
import "../../domain/model_budget.dart";
import "../builtin/llm/llm_client.dart";
import "../builtin/llm/providers/provider.dart";
import "channel_generation.dart";
import "../model_host/model_process.dart";

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
  const AppleFmProbe(
    this.reason, {
    this.mlx = false,
    this.budget = const ModelBudget.unknown(),
  });

  final String reason;

  /// What the device can give an MLX model, from what Metal and the OS said.
  final ModelBudget budget;

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

/// The Apple system model, gated on its own availability. Nothing is held
/// between calls, so [close] is nothing and a rebuilt client costs nothing —
/// the registry can cache or drop this as it likes.
class AppleFmClient implements LlmClient {
  AppleFmClient(this.probe);

  final AppleFmProbe probe;

  /// The system model is the OS's own process already, so its channel is
  /// always this one's.
  final ModelChannel _channel = PlatformModelChannel(appleChannel);

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
    if (probe.reason != "available") throw probe.unavailable;
    yield* ChannelGeneration(_channel, label: "Apple on-device model").run(
      "generate",
      {
        "instructions": joinedSystemText(messages),
        "history": _transcript(messages),
        // A trailing tool result is worded the way the history words one, or
        // the model reads it as something the user typed.
        "prompt": messages.last.role == LlmRole.tool
            ? _toolResultText(messages.last, _toolNames(messages))
            : channelText(messages.last),
        "tools": [for (final tool in tools) channelTool(tool)],
        "temperature": ?temperature,
      },
    );
  }
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
          LlmRole.user => {"role": "user", "text": channelText(message)},
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
