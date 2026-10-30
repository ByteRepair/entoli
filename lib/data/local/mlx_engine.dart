import "dart:async";

import "package:flutter/services.dart";
import "package:path/path.dart" as p;

import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../builtin/llm/llm_client.dart";
import "../builtin/llm/openai_client.dart";
import "../model_host/model_host.dart";
import "apple_fm.dart";
import "local_engine.dart";
import "local_instance.dart";

/// MLX through mlx-swift-lm: iOS 27 and macOS 27, where the build links the
/// package. Its models are loaded by the Swift half of [appleChannel], in
/// whichever process the [ModelHost] says — the model host on macOS, this one
/// on iOS. See "The MLX models" in `ios/AGENTS.md`.
class MlxEngine extends RuntimeEngine {
  MlxEngine(LocalModelStore store, ModelHost host, {super.prompts})
    : super(
        MlxRuntime(host.channel(appleChannel.name), promptDir: prompts?.dir),
        store,
      ) {
    // The models were the host process's, and it has gone: a new one starts
    // with none loaded.
    host.lost.listen((_) => residency.lost());
  }

  @override
  List<LocalModel> get catalog => mlxCatalog;
}

/// How an MLX model is loaded: by name and directory, over the channel to its
/// Swift half. The GPU is the only device, so there is no device or thread
/// count to choose, and MLX's cache grows as it is used rather than being
/// sized at load, so there is no context to choose either.
class MlxRuntime extends LocalRuntime {
  const MlxRuntime(this._channel, {this.promptDir});

  final ModelChannel _channel;

  /// Where prompt state is saved, or null where none is kept.
  final String? promptDir;

  @override
  Set<LocalControl> get controls => const {
    LocalControl.maxRunning,
    LocalControl.kvCache,
  };

  @override
  Future<LocalLoad> resolve(
    DownloadedModel model,
    LocalOptions options,
  ) async => LocalLoad(
    contextLength: model.contextLength,
    keepsPrompts: options.keepsPrompts && promptDir != null,
  );

  @override
  LocalInstance create(
    DownloadedModel model,
    LocalLoad load, {
    required void Function() onChange,
  }) => MlxInstance(
    _channel,
    model,
    load,
    promptDir: promptDir,
    onChange: onChange,
  );
}

/// One MLX model, loaded in the Swift half and kept there until it is stopped.
class MlxInstance extends LocalInstance {
  MlxInstance(
    this._channel,
    this.model,
    this.load, {
    required this.promptDir,
    required this._onChange,
  });

  /// Where its prompt state files go.
  final String? promptDir;

  final void Function() _onChange;

  final ModelChannel _channel;

  @override
  final DownloadedModel model;

  @override
  final LocalLoad load;

  final _ready = Completer<void>();
  var _phase = LocalLlmPhase.starting;
  String? _failure;

  @override
  Future<void> get ready => _ready.future;

  /// The device named the way the settings page names one, so its running row
  /// says where a model answers.
  @override
  LocalLlmState get state => LocalLlmState(
    modelId: model.id,
    phase: _phase,
    device: "Metal",
    contextLength: load.contextLength,
    failure: _failure,
  );

  @override
  void start() => unawaited(_load(_onChange));

  Future<void> _load(void Function() onChange) async {
    try {
      await _channel.invokeMethod("load", {
        "model": model.id,
        "directory": model.file,
      });
      _phase = LocalLlmPhase.ready;
      _ready.complete();
    } on PlatformException catch (e) {
      _fail(e.message ?? e.code);
    } catch (e) {
      _fail("$e");
    }
    onChange();
  }

  /// The row carries the reason alone — the settings page names the model
  /// above it — and the turn is told both.
  void _fail(String why) {
    _phase = LocalLlmPhase.failed;
    _failure = why;
    _ready.completeError(LocalLlmFailure("${model.name} would not load: $why"));
    _ready.future.ignore();
  }

  /// The whole conversation, every call: the Swift half keeps what the
  /// model's cache holds of it and reads only the rest, so an agent's turn
  /// reads its long prompt once rather than at every step. See "The MLX
  /// models" in `ios/AGENTS.md`.
  @override
  Stream<LlmChunk> generate(
    List<LlmMessage> messages, {
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) => ChannelGeneration(_channel, label: "on-device model", callEnds: false)
      .run("mlxGenerate", {
        "model": model.id,
        "directory": model.file,
        // One system message: a chat template refuses a second, and the
        // agent sends two. See [mergeLeadingSystem].
        "messages": [
          for (final message in mergeLeadingSystem(messages)) _wire(message),
        ],
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

  /// A message as the Swift half reads it. What rode with a user's message is
  /// named rather than sent, since a text model cannot read the bytes.
  static Map<String, Object?> _wire(LlmMessage message) => {
    "role": message.role.name,
    "content": [
      message.text,
      for (final attachment in message.attachments)
        attachment.isText
            ? "${attachment.filename}:\n${attachment.asText}"
            : "[Attached file, not readable by this model: "
                  "${attachment.filename}]",
    ].where((part) => part.isNotEmpty).join("\n\n"),
    if (message.toolCalls.isNotEmpty)
      "toolCalls": [
        for (final call in message.toolCalls)
          {"id": call.id, "name": call.name, "arguments": call.argumentsJson},
      ],
    "toolCallId": ?message.toolCallId,
  };

  @override
  Future<bool> saveState(String file) => _state("mlxSave", file);

  @override
  Future<bool> restoreState(String file) => _state("mlxRestore", file);

  Future<bool> _state(String method, String file) async {
    final dir = promptDir;
    if (dir == null || !load.keepsPrompts) return false;
    try {
      return await _channel.invokeMethod<bool>(method, {
            "model": model.id,
            "path": p.join(dir, file),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod("evict", {"model": model.id});
    } catch (_) {
      // Its process may have gone already, which is the same answer.
    }
  }
}
