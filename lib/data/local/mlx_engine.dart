import "dart:async";

import "package:flutter/services.dart";

import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../builtin/llm/llm_client.dart";
import "../model_host/model_host.dart";
import "apple_fm.dart";
import "local_engine.dart";
import "local_instance.dart";

/// MLX through mlx-swift-lm: iOS 27 and macOS 27, where the build links the
/// package. Its models are loaded by the Swift half of [appleChannel], in
/// whichever process the [ModelHost] says — the model host on macOS, this one
/// on iOS. See "The MLX models" in `ios/AGENTS.md`.
class MlxEngine extends RuntimeEngine {
  MlxEngine(LocalModelStore store, ModelHost host)
    : super(MlxRuntime(host.channel(appleChannel.name)), store) {
    // The models were the host process's, and it has gone: a new one starts
    // with none loaded.
    host.lost.listen((_) => residency.lost());
  }

  @override
  List<LocalModel> get catalog => mlxCatalog;
}

/// How an MLX model is loaded: by name and directory, over the channel to its
/// Swift half. The GPU is the only device, so there is no device or thread
/// count to choose.
class MlxRuntime extends LocalRuntime {
  const MlxRuntime(this._channel);

  final ModelChannel _channel;

  @override
  Set<LocalControl> get controls => const {LocalControl.maxRunning};

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
  }) => MlxInstance(_channel, model, load, onChange: onChange);
}

/// One MLX model, loaded in the Swift half and kept there until it is stopped.
class MlxInstance extends LocalInstance {
  MlxInstance(this._channel, this.model, this.load, {required this._onChange});

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

  @override
  Stream<LlmChunk> generate(
    List<LlmMessage> messages, {
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) => _MlxGeneration(_channel, model).stream(
    messages,
    model: model.id,
    tools: tools,
    temperature: temperature,
    reasoningEffort: reasoningEffort,
  );

  @override
  Future<bool> saveState(String file) async => false;

  @override
  Future<bool> restoreState(String file) async => false;

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod("evict", {"model": model.id});
    } catch (_) {
      // Its process may have gone already, which is the same answer.
    }
  }
}

/// A generation on a loaded MLX model, through the Foundation Models
/// framework the Apple system model runs on: the channel is told which model
/// and where its files are.
class _MlxGeneration extends FoundationModelsClient {
  _MlxGeneration(super.channel, this._model);

  final DownloadedModel _model;

  @override
  String get label => "on-device model";

  @override
  Future<Map<String, Object?>> route(String model) async => {
    "model": _model.id,
    "directory": _model.file,
  };
}
