import "dart:async";

import "package:flutter/services.dart";
import "package:http/http.dart" as http;

import "../../domain/local_model.dart";
import "../../domain/llm_provider.dart";
import "../builtin/llm/llm_client.dart";
import "../builtin/llm/providers/provider.dart";

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
/// `llmEndpoints` beside the llama pool, so the registry, the pickers, a
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
  /// one. The handshake says so, because what a build links is the build's
  /// answer, the same way the llama backends are the server's.
  final bool mlx;

  LlmException get unavailable => switch (reason) {
        "not-enabled" => const LlmException(
            "Apple Intelligence is not enabled. It is a system setting, not "
            "this app's: set it in Settings, and the next turn reaches this "
            "model."),
        "not-ready" => const LlmException(
            "The Apple on-device model is not ready yet; the system is still "
            "fetching it.",
            retryable: true),
        _ => const LlmException("The Apple on-device model is unavailable."),
      };
}

/// The MLX models the channel offers beside the system model, when this
/// build links mlx-swift-lm's `MLXFoundationModels` (the one-tap Xcode
/// addition `ios/AGENTS.md` carries) and the OS is 27. The rows stop well
/// inside the 6B an 8GB iPhone can hold beside the rest of the app; the
/// framework fetches what a row names from Hugging Face at first turn and
/// caches it, which is why nothing here pins a checksum.
/// shortcut: weights arrive unpinned from mlx-community, and the list is
/// the Apple-verified example alone — rows are one edited line each;
/// owning the fetch the way the GGUF catalog does is the upgrade the
/// supply chain may demand.
const mlxModels = <String>["mlx-community/Qwen3.5-4B-4bit"];

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

class AppleFmProvider extends LlmProvider with KeyFree, ChatOnly {
  const AppleFmProvider(super.config, this.probe);

  final AppleFmProbe probe;

  @override
  LlmClient client(String? apiKey) => AppleFmClient(probe);

  @override
  Future<List<String>> listModels(String? apiKey, {http.Client? httpClient}) async =>
      [appleModelId, if (probe.mlx) ...mlxModels];
}

/// Everything the channel says, broadcast — the `NativeVoiceBridge` shape:
/// `setMethodCallHandler` takes one handler, so a second client's
/// registration would land on the first's, and the bridge owns it while the
/// clients filter by generation id.
class AppleFmBridge {
  AppleFmBridge._install() {
    appleChannel.setMethodCallHandler((call) async {
      incoming.add(call);
    });
  }

  static final shared = AppleFmBridge._install();

  final incoming = StreamController<MethodCall>.broadcast();

  Stream<MethodCall> get calls => incoming.stream;
}

/// The Apple on-device model, as a client. Nothing is held between calls, so
/// [close] is nothing and a rebuilt client costs nothing — the registry can
/// cache or drop this as it likes.
class AppleFmClient implements LlmClient {
  AppleFmClient(this.probe);

  final AppleFmProbe probe;

  /// One counter for the whole process, across every client the registry
  /// ever built: a generation id must not mean two things to one bridge.
  static var _generations = 0;

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
    // The system model's gate is its own availability. An MLX row's is not:
    // it runs on the GPU whether Apple Intelligence is on at all or not —
    // the handshake's `mlx` is the whole of that gate.
    if (model == appleModelId && probe.reason != "available") {
      throw probe.unavailable;
    }
    final generation = "fm${++_generations}";

    // The state the completion's message is assembled from — locals, not
    // fields: one client is the registry's one cache entry, and concurrent
    // streams of its own would have been one buffer each.
    final textSoFar = StringBuffer();
    final calls = <LlmToolCall>[];

    // Registered before the request goes out, so a frame the platform sent
    // early cannot fall between the request and its listener.
    final events = StreamController<MethodCall>();
    final subscription = AppleFmBridge.shared.calls
        .where((call) => (call.arguments as Map?)?["id"] == generation)
        .listen(events.add);
    var finished = false;
    try {
      await appleChannel.invokeMethod("generate", {
        "id": generation,
        // The model id is the route: the system model by name, and every
        // MLX row by its package's own id.
        "model": model,
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
          case "toolCall":
            final args = call.arguments as Map?;
            calls.add(LlmToolCall(
              id: "c${calls.length}",
              name: args?["name"] as String? ?? "",
              argumentsJson: args?["arguments"] as String? ?? "{}",
            ));
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
              args?["code"] as String? ?? "other",
              args?["message"] as String? ?? "",
            );
        }
      }
      throw const LlmException("The Apple on-device model never answered.",
          statusCode: 502);
    } finally {
      // Unsubscribe first: a cancel arriving at the Swift half cannot race a
      // generation this client is still reading.
      await subscription.cancel();
      await events.close();
      if (!finished) {
        try {
          await appleChannel.invokeMethod("cancel", {"id": generation});
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

/// The user's words, with what rode with them. Text attachments are inlined;
/// anything else is named, because a model that cannot read it is better
/// told it exists than handed bytes — the same rule the wire shape carries.
String _promptText(LlmMessage message) {
  final text = StringBuffer(message.text);
  for (final attachment in message.attachments) {
    if (attachment.isText) {
      text.writeln("\n${attachment.filename}:\n${attachment.asText}");
    } else {
      text.writeln("\n[Attached file, not readable by this model: ${attachment.filename}]");
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
LlmException _errorOf(String code, String message) => switch (code) {
      "context" => const LlmException(
          "The conversation has outgrown the Apple on-device model's context "
          "window. Compact the chat, or lower Total Context under "
          "Settings > LLMs."),
      "guardrail" => const LlmException(
          "The Apple on-device model's guardrails refused this request."),
      "rate-limit" => const LlmException(
          "The Apple on-device model is rate limited.",
          retryable: true),
      "assets" => const LlmException(
          "The Apple on-device model's assets are not ready; the system is "
          "still fetching them.",
          retryable: true),
      "language" => const LlmException(
          "The on-device model does not support this conversation's "
          "language."),
      "resources" => const LlmException(
          "The Apple on-device model ran short of device resources."),
      _ => LlmException(
          message.isEmpty
              ? "The Apple on-device model failed."
              : "The Apple on-device model failed: $message"),
    };
