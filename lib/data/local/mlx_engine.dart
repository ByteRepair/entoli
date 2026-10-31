import "dart:async";

import "package:flutter/services.dart";

import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../builtin/llm/llm_client.dart";
import "../model_host/model_host.dart";
import "apple_fm.dart";
import "channel_generation.dart";
import "local_engine.dart";
import "local_instance.dart";

/// MLX through mlx-swift-lm: iOS 27 and macOS 27, where the build links the
/// package. Its models are loaded by the Swift half of [appleChannel], in
/// whichever process the [ModelHost] says — the model host on macOS, this one
/// on iOS. See "The MLX models" in `ios/AGENTS.md`.
class MlxEngine extends RuntimeEngine {
  MlxEngine(
    LocalModelStore store,
    ModelHost host, {
    super.prompts,
    super.budget,
  }) : _host = host,
       super(MlxRuntime(host), store) {
    // The models were the host process's, and it has gone: a new one starts
    // with none loaded.
    host.lost.listen((_) => residency.lost());
  }

  final ModelHost _host;

  @override
  List<LocalModel> get catalog => mlxCatalog;

  /// Where the models have a process of their own, all of it: every model
  /// in it shares one runtime, one Metal device and one buffer cache, which
  /// the rows' sum would leave out. In the app's own process, the rows.
  @override
  Future<int?> totalBytes() async =>
      await _host.footprint() ?? await super.totalBytes();
}

/// How an MLX model is loaded: by name and directory, over the channel to its
/// Swift half. The GPU is the only device, so there is no device or thread
/// count to choose, and MLX's cache grows as it is used rather than being
/// sized at load, so there is no context to choose either. Keeping prompts
/// changes nothing about a load, so it is not in one.
class MlxRuntime extends LocalRuntime {
  MlxRuntime(this._host) : _channel = _host.channel(appleChannel.name);

  final ModelHost _host;
  final ModelChannel _channel;

  @override
  Set<LocalControl> get controls => const {
    LocalControl.maxRunning,
    LocalControl.kvCache,
  };

  @override
  Future<LocalLoad> resolve(
    DownloadedModel model,
    LocalOptions options,
  ) async => LocalLoad(contextLength: model.contextLength);

  @override
  LocalInstance create(
    DownloadedModel model,
    LocalLoad load, {
    required void Function() onChange,
  }) => MlxInstance(_channel, _host.hold(), model, load, onChange: onChange);
}

/// One MLX model, loaded in the Swift half and kept there until it is stopped.
class MlxInstance extends LocalInstance {
  MlxInstance(
    this._channel,
    this._lease,
    super.model,
    super.load, {
    required super.onChange,
  });

  final ModelChannel _channel;

  /// Keeps the process the model is in, from when it is made — before the
  /// model it displaces lets go of its own, so a switch of models is not the
  /// process going idle — until it is unloaded.
  final ModelHostLease _lease;

  @override
  String get deviceLabel => "Metal";

  @override
  String get stateFormat => "mlx";

  @override
  void start() => unawaited(_load());

  Future<void> _load() async {
    try {
      await _channel.invokeMethod("load", {
        "model": model.id,
        "directory": model.file,
      });
      markReady();
    } on PlatformException catch (e) {
      markFailed(e.message ?? e.code);
    } catch (e) {
      markFailed("$e");
    }
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
  }) =>
      ChannelGeneration(_channel, label: "on-device model").run("mlxGenerate", {
        "model": model.id,
        "messages": [for (final message in messages) _wire(message)],
        "tools": [for (final tool in tools) channelTool(tool)],
        "temperature": ?temperature,
      });

  /// A message as the Swift half reads it.
  static Map<String, Object?> _wire(LlmMessage message) => {
    "role": message.role.name,
    "content": channelText(message),
    if (message.toolCalls.isNotEmpty)
      "toolCalls": [
        for (final call in message.toolCalls)
          {"id": call.id, "name": call.name, "arguments": call.argumentsJson},
      ],
    "toolCallId": ?message.toolCallId,
  };

  /// The weights, counted by the Swift half, and the cache, as the tokens it
  /// holds at what one costs this model.
  @override
  Future<LocalUsage?> usage() async {
    try {
      final usage = await _channel.invokeMethod<Map<Object?, Object?>>(
        "mlxUsage",
        {"model": model.id},
      );
      if (usage == null) return null;
      final tokens = usage["tokens"] as int? ?? 0;
      return LocalUsage(
        bytes:
            (usage["weightBytes"] as int? ?? 0) +
            tokens * model.kvBytesPerToken,
        tokens: tokens,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> saveState(String path) => _state("mlxSave", path);

  @override
  Future<bool> restoreState(String path) => _state("mlxRestore", path);

  Future<bool> _state(String method, String path) async {
    try {
      return await _channel.invokeMethod<bool>(method, {
            "model": model.id,
            "path": path,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> unload() async {
    try {
      await _channel.invokeMethod("evict", {"model": model.id});
    } catch (_) {
      // Its process may have gone already, which is the same answer.
    } finally {
      _lease.release();
    }
  }
}
