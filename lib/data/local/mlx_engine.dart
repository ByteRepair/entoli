import "dart:async";
import "dart:io" show FileSystemException;

import "package:flutter/services.dart";
import "package:entoli_core/model/local_model.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/local_model_store.dart";
import "package:entoli_core/agent/llm/llm_client.dart";
import "package:entoli_core/model/model_process.dart";

import "channel_generation.dart";
import "local_engine.dart";
import "local_instance.dart";
import "model_format.dart";

/// The MLX models' channel, whose Swift half (`MlxChannel.swift`) is
/// registered only where they run: the model host on macOS, the app on iOS.
const mlxChannel = MethodChannel("agent_chat/mlx");

/// MLX through mlx-swift-lm: iOS 27 and macOS 27, where the build links the
/// package. Its models are loaded by the Swift half of [mlxChannel], in
/// whichever process the [ModelProcess] says — the model host on macOS, this one
/// on iOS. See "The MLX models" in `ios/AGENTS.md`.
class MlxEngine extends RuntimeEngine {
  MlxEngine(
    LocalModelStore store,
    ModelProcess process, {
    super.prompts,
    super.launch,
    super.memory,
    bool budgetRequired = false,
  }) : _process = process,
       super(
         MlxRuntime(
           process,
           budget: launch?.budget.bytes,
           budgetRequired: budgetRequired,
         ),
         store,
       );

  final ModelProcess _process;

  @override
  List<LocalModel> get catalog => mlxCatalog;

  /// Where the models have a process of their own, all of it: every model
  /// in it shares one runtime, one Metal device and one buffer cache, which
  /// the rows' sum would leave out. In the app's own process, the rows.
  @override
  Future<int?> footprint() => _process.footprint();
}

/// How an MLX model is loaded: by name and directory, over the channel to its
/// Swift half. The GPU is the only device, so there is no device or thread
/// count to choose, and the context is the [BudgetPlan]'s, so there is none
/// to choose there either. Keeping prompts changes nothing about a load, so
/// it is not in one.
class MlxRuntime extends LocalRuntime {
  MlxRuntime(this._process, {this.budget, this.budgetRequired = false})
    : _channel = _process.channel(mlxChannel.name);

  final ModelProcess _process;
  final ModelChannel _channel;

  /// What every MLX model together may take, measured at launch; null where
  /// the device said nothing, which leaves MLX its own defaults.
  final int? budget;

  /// Whether a model may not run without [budget]: an iPhone, whose app iOS
  /// ends past a limit nothing else would hold MLX inside.
  final bool budgetRequired;

  /// Each model's shape, read off its config once — the chat's window asks
  /// for the plan on every read — and read again for files that changed.
  final _shapes = <String, ModelShape>{};

  /// Each model gets an equal share of [budget], so the models
  /// `maxRunning` lets be resident together fit beside each other.
  @override
  MemoryPlan plan(DownloadedModel model, LocalOptions options) {
    final budget = this.budget;
    if (budget == null) {
      return UnplannedMemory(
        model.contextLength,
        refusal: budgetRequired
            ? "the device did not say how much memory the app may use"
            : null,
      );
    }
    final ModelShape shape;
    try {
      shape = _shapes["${model.id}\u0000${model.file}\u0000${model.bytes}"] ??=
          MlxFormat.shapeOf(model);
    } on FormatException catch (e) {
      return UnplannedMemory(model.contextLength, refusal: e.message);
    } on FileSystemException catch (e) {
      return UnplannedMemory(model.contextLength, refusal: e.message);
    }
    return BudgetPlan(
      shape,
      budgetBytes: budget ~/ options.maxRunning,
      sharedBy: options.maxRunning,
    );
  }

  @override
  Set<LocalControl> get controls => const {
    LocalControl.maxRunning,
    LocalControl.kvCache,
  };

  @override
  Future<LocalLoad> resolve(
    DownloadedModel model,
    LocalOptions options,
  ) async => LocalLoad(memory: plan(model, options));

  @override
  LocalInstance create(
    DownloadedModel model,
    LocalLoad load, {
    required void Function() onChange,
  }) => MlxInstance(_channel, _process.hold(), model, load, onChange: onChange);
}

/// One MLX model, loaded in the Swift half and kept there until it is stopped.
class MlxInstance extends LocalInstance {
  MlxInstance(
    this._channel,
    this._lease,
    super.model,
    super.load, {
    required super.onChange,
  }) {
    // A row that says why, as a llama.cpp server that exited leaves one, and
    // the next turn to ask for the model loads it again in a new process.
    unawaited(
      _lease.lost.then(
        (_) => markFailed("The model host quit, taking the model with it."),
      ),
    );
  }

  final ModelChannel _channel;

  /// Keeps the process the model is in, from when it is made — before the
  /// model it displaces lets go of its own, so a switch of models is not the
  /// process going idle — until it is unloaded, or the process goes.
  final ModelProcessLease _lease;

  @override
  String get deviceLabel => "Metal";

  @override
  String get stateFormat => "mlx";

  @override
  void start() => unawaited(_load());

  Future<void> _load() async {
    final memory = load.memory;
    if (memory.refusal case final why?) return markFailed(why);
    try {
      await _channel.invokeMethod("load", {
        "model": model.id,
        "directory": model.file,
        if (memory is BudgetPlan) ...{
          "budget": memory.budgetBytes,
          "cache": BudgetPlan.cacheBytes,
          "context": memory.contextLength,
          "prefillStep": memory.prefillStep,
        },
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
    LlmOutputLimit outputLimit = const LlmOutputLimit(),
  }) =>
      ChannelGeneration(
        _channel,
        label: "on-device model",
        onDone: _checkPeak,
      ).run("generate", {
        "model": model.id,
        "messages": [for (final message in messages) _wire(message)],
        "tools": [for (final tool in tools) channelTool(tool)],
        "temperature": ?temperature,
        // Always a number: the Swift half has to stop somewhere, and says the
        // reply was cut off where it stopped here.
        "maxTokens": outputLimit.tokens,
      });

  /// A reply whose peak came within a tenth of MLX's budget says the plans'
  /// working memory is short of what MLX takes. Both are the process's —
  /// every loaded model's — as MLX counts them.
  void _checkPeak(Map<Object?, Object?> done) {
    final peak = done["peakBytes"], budget = done["budgetBytes"];
    if (peak is! int || budget is! int) return;
    if (peak * 10 > budget * 9) {
      logFailure("mlx", "${model.id} peaked at $peak of a $budget budget");
    }
  }

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
    // Asked of a model whose process went, a channel call would start
    // another for nothing: the Running row polls this.
    if (_lease.isLost) return null;
    try {
      final usage = await _channel.invokeMethod<Map<Object?, Object?>>(
        "usage",
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

  /// The Swift half drops its session's record at the start of a generation
  /// and takes it up again only when one finishes: a reply stopped part-way
  /// leaves a cache holding some of a reply nobody kept.
  @override
  bool get keepsUnfinished => false;

  @override
  Future<bool> saveState(String path) => _state("save", path);

  @override
  Future<bool> restoreState(String path) => _state("restore", path);

  Future<bool> _state(String method, String path) async {
    if (_lease.isLost) return false;
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
    // Its process went, and the model with it: there is nothing left to
    // evict, and asking would only start another process.
    if (_lease.isLost) return;
    try {
      await _channel.invokeMethod("evict", {"model": model.id});
    } catch (_) {
      // Its process may have gone already, which is the same answer.
    } finally {
      _lease.release();
    }
  }
}
