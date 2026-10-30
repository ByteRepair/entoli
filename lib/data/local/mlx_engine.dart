import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../../domain/app_settings.dart";
import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../builtin/llm/llm_client.dart";
import "apple_fm.dart";
import "local_engine.dart";

/// MLX, run by the Foundation Models framework through mlx-swift-lm: iOS 27
/// and macOS 27, where the build links the package. The Swift half of
/// [appleChannel] loads a model from its directory, keeps it resident until
/// it is evicted, and runs each generation the way it runs the Apple system
/// model's — so tool calls arrive decoded, as they do there.
///
/// Residency is decided here, the way the llama pool decides it: past
/// `maxLocalModels` the least recently served is evicted before the next one
/// loads, so two sets of weights are never mapped where one was asked for.
class MlxEngine extends LocalEngine {
  MlxEngine(this.store);

  @override
  final LocalModelStore store;

  static const _channel = appleChannel;

  /// One load per model, so two turns asking at once wait on the same one.
  final _loads = <String, Future<void>>{};

  @override
  List<LocalModel> get catalog => mlxCatalog;

  /// The GPU is the only device and the framework sizes the cache itself, so
  /// how many may be resident is the one thing left to choose.
  @override
  Set<LocalControl> get controls => const {LocalControl.maxRunning};

  @override
  final ValueNotifier<List<LocalLlmState>> running = ValueNotifier(const []);

  /// Where [modelId]'s files are, once it is resident.
  Future<String> serve(String modelId, {int maxRunning = 1}) async {
    final model = store.downloadedOfSync(modelId);
    if (model == null) {
      throw LlmException("$modelId is not downloaded on this device.");
    }
    final pending = _loads[modelId];
    if (pending != null) {
      await pending;
    } else if (_stateOf(modelId)?.phase != LocalLlmPhase.ready) {
      final load = _load(model, maxRunning);
      _loads[modelId] = load;
      try {
        await load;
      } finally {
        _loads.remove(modelId);
      }
    }
    _touch(modelId);
    return model.file;
  }

  Future<void> _load(DownloadedModel model, int maxRunning) async {
    final others = [for (final state in running.value) if (state.modelId != model.id) state];
    // Evicted before the next loads, never after: overlapping them is the
    // memory the cap exists to keep free.
    while (others.length >= maxRunning && others.isNotEmpty) {
      final oldest = others.removeAt(0);
      await _channel.invokeMethod("evict", {"model": oldest.modelId});
    }
    _publish([...others, _state(model.id, LocalLlmPhase.starting)]);
    try {
      await _channel.invokeMethod("load", {"model": model.id, "directory": model.file});
    } on PlatformException catch (e) {
      final why = e.message ?? e.code;
      _replace(model.id, _state(model.id, LocalLlmPhase.failed, failure: why));
      throw LlmException("${model.name} would not load: $why");
    }
    _replace(model.id, _state(model.id, LocalLlmPhase.ready));
  }

  @override
  Future<void> stopAll() async {
    await _channel.invokeMethod("evictAll");
    _publish(const []);
  }

  @override
  LlmClient client(AppSettings Function() settings) => MlxClient(this, settings);

  LocalLlmState? _stateOf(String id) =>
      running.value.where((state) => state.modelId == id).firstOrNull;

  /// Named the way the settings page names a device, so its running row says
  /// where a model answers.
  static LocalLlmState _state(String id, LocalLlmPhase phase, {String? failure}) =>
      LocalLlmState(modelId: id, phase: phase, device: "Metal", failure: failure);

  void _replace(String id, LocalLlmState state) => _publish(
      [for (final each in running.value) each.modelId == id ? state : each]);

  /// Most recently served last, which is what eviction reads.
  void _touch(String id) {
    final state = _stateOf(id);
    if (state == null) return;
    _publish([...running.value.where((each) => each.modelId != id), state]);
  }

  void _publish(List<LocalLlmState> states) => running.value = List.unmodifiable(states);
}

/// An MLX model, asked through the channel once [MlxEngine] has it resident.
class MlxClient extends FoundationModelsClient {
  MlxClient(this._engine, this._settings);

  final MlxEngine _engine;
  final AppSettings Function() _settings;

  @override
  String get label => "on-device model";

  @override
  Future<Map<String, Object?>> route(String model) async => {
        "model": model,
        "directory":
            await _engine.serve(model, maxRunning: _settings().maxLocalModels),
      };
}
