import "package:flutter/foundation.dart";

import "../../domain/local_llm.dart";
import "../../domain/local_model_store.dart";
import "local_instance.dart";

/// Which models are loaded, and the one rule for loading another: at most
/// [LocalOptions.maxRunning], the least recently served stopped first, and
/// stopped *before* the next one loads — overlapping them would put two sets of
/// weights in memory at once, which is the thing the cap exists to prevent.
/// Every runtime gets this rule from here rather than writing its own.
///
/// [serve] is the only thing that reconciles what is loaded with the settings,
/// and there is no second path to forget: a model loaded under the same
/// [LocalLoad] is answered untouched, one loaded under a different one is
/// loaded again, and one not loaded is loaded.
class Residency {
  Residency(this._runtime, this._store);

  final LocalRuntime _runtime;

  /// Asked synchronously at the moment of loading, so a model deleted behind
  /// the app's back is a refusal here rather than a load that fails later
  /// saying it could not open a file.
  final LocalModelStore _store;

  /// Least recently served first, which is the order [serve] stops them in.
  final _loaded = <LocalInstance>[];

  /// What is loaded and how far each one has got, least recently served first.
  /// A [ValueListenable] rather than a stream because the settings page draws
  /// it, and a rebuild per frame of a model load is the wrong shape.
  final ValueNotifier<List<LocalLlmState>> running = ValueNotifier(const []);

  /// [modelId], loading it first where it is not loaded under these
  /// [options]. Completes once it will answer, or throws a [LocalLlmFailure]
  /// saying why it never will.
  Future<LocalInstance> serve(String modelId, LocalOptions options) async {
    final model = _store.downloadedOfSync(modelId);
    if (model == null) throw LocalLlmFailure("$modelId is not downloaded.");
    final load = await _runtime.resolve(model, options);

    // A failed one is never the one being asked for: being asked again is the
    // user asking for another go, and there is nothing else they could press
    // to get one.
    final already = instanceOf(modelId);
    if (already != null && !already.failed && already.load == load) {
      _touch(already);
      await already.ready;
      return already;
    }

    // Every list edit below happens before the first await, so two turns
    // asking at once cannot both decide to load the same model — the second
    // finds the first already in the list and waits on it.
    final stopping = <LocalInstance>[];
    if (already != null) {
      _loaded.remove(already);
      stopping.add(already);
    }
    final cap = options.maxRunning.clamp(1, maxLocalModelsAllowed);
    while (_loaded.length >= cap) {
      stopping.add(_loaded.removeAt(0));
    }
    final instance = _runtime.create(model, load, onChange: _publish);
    _loaded.add(instance);
    _publish();

    await Future.wait([for (final old in stopping) old.stop()]);
    instance.start();
    await instance.ready;
    return instance;
  }

  /// Unloads [modelId], where it is loaded.
  Future<void> stop(String modelId) async {
    final instance = instanceOf(modelId);
    if (instance == null) return;
    _loaded.remove(instance);
    _publish();
    await instance.stop();
  }

  Future<void> stopAll() async {
    final all = [..._loaded];
    _loaded.clear();
    _publish();
    await Future.wait([for (final instance in all) instance.stop()]);
  }

  /// Forgets every instance without stopping it: the process they were in has
  /// gone, and them with it.
  void lost() {
    _loaded.clear();
    _publish();
  }

  /// The loaded instance of [modelId], or null where it is not loaded.
  LocalInstance? instanceOf(String modelId) {
    for (final instance in _loaded) {
      if (instance.model.id == modelId) return instance;
    }
    return null;
  }

  /// Most recently served last, since that is the end [serve] evicts from.
  /// Already last is the common case — every step of a turn — and publishes
  /// nothing, since nothing moved.
  void _touch(LocalInstance instance) {
    if (_loaded.last == instance || !_loaded.remove(instance)) return;
    _loaded.add(instance);
    _publish();
  }

  void _publish() =>
      running.value = [for (final instance in _loaded) instance.state];
}
