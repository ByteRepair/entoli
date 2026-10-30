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

  /// Each resident model's load, by id: two turns asking at once wait on the
  /// same one, and a model that is in here is never loaded again.
  final _resident = <String, Future<void>>{};

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
    try {
      await (_resident[modelId] ??=
          _load(model, maxRunning.clamp(1, maxLocalModelsAllowed)));
    } catch (_) {
      _resident.remove(modelId);
      rethrow;
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
      _resident.remove(oldest.modelId);
      await appleChannel.invokeMethod("evict", {"model": oldest.modelId});
    }
    _publish([...others, _state(model, LocalLlmPhase.starting)]);
    try {
      await appleChannel.invokeMethod("load", {"model": model.id, "directory": model.file});
    } on PlatformException catch (e) {
      final why = e.message ?? e.code;
      _replace(model.id, _state(model, LocalLlmPhase.failed, failure: why));
      throw LlmException("${model.name} would not load: $why");
    }
    _replace(model.id, _state(model, LocalLlmPhase.ready));
  }

  @override
  Future<void> stopAll() async {
    _resident.clear();
    await appleChannel.invokeMethod("evictAll");
    _publish(const []);
  }

  @override
  LlmClient client(AppSettings Function() settings) => MlxClient(this, settings);

  /// The device named the way the settings page names one, so its running row
  /// says where a model answers. The context is the model's own: MLX's cache
  /// grows as it is used rather than being sized at load.
  static LocalLlmState _state(DownloadedModel model, LocalLlmPhase phase,
          {String? failure}) =>
      LocalLlmState(
        modelId: model.id,
        phase: phase,
        device: "Metal",
        contextLength: model.contextLength,
        failure: failure,
      );

  void _replace(String id, LocalLlmState state) => _publish(
      [for (final each in running.value) each.modelId == id ? state : each]);

  /// Most recently served last, which is what eviction reads.
  void _touch(String id) {
    final states = running.value;
    if (states.isEmpty || states.last.modelId == id) return;
    final state = states.where((each) => each.modelId == id).firstOrNull;
    if (state == null) return;
    _publish([...states.where((each) => each.modelId != id), state]);
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
