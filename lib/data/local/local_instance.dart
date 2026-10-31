import "dart:async";

import "package:flutter/foundation.dart" show protected;

import "../../domain/app_settings.dart";
import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../builtin/llm/llm_client.dart";

/// How a model is to be loaded, as a turn asks for it. Read from the settings
/// fresh for every call, the way `LocalShell` re-reads its environment, so a
/// change reaches the next turn rather than the next launch.
///
/// What a runtime makes of it — the device "auto" resolves to, the context a
/// model defaults to — is [LocalLoad]; this is what was asked.
class LocalOptions {
  const LocalOptions({
    required this.maxRunning,
    required this.keptPrompts,
    this.device,
    this.contextLength,
    this.threads,
  });

  /// The settings' answer. One reading so the client that reaches a model and
  /// the prefill that warms it read them the same way — a loaded model is
  /// reused only under the same [LocalLoad], so a warm built from a different
  /// reading would be thrown away rather than reused. `keptPrompts` collapses
  /// the "Default (10)" the UI shows into the number the cache counts.
  LocalOptions.fromSettings(AppSettings settings)
    : this(
        device: settings.localModelDevice,
        contextLength: settings.localModelContext,
        maxRunning: settings.maxLocalModels,
        threads: settings.localModelThreads,
        keptPrompts:
            settings.localModelKvCachePrompts ??
            AppSettings.defaultKvCachePrompts,
      );

  final String? device;
  final int? contextLength;
  final int maxRunning;
  final int? threads;
  final int keptPrompts;

  /// Whether prompts are kept on disk between turns: the one place
  /// zero-means-off is read as a yes or no.
  bool get keepsPrompts => keptPrompts > 0;

  ({String? d, int? c, int m, int? t, int k}) get _fields =>
      (d: device, c: contextLength, m: maxRunning, t: threads, k: keptPrompts);

  @override
  bool operator ==(Object other) =>
      other is LocalOptions && other._fields == _fields;

  @override
  int get hashCode => _fields.hashCode;
}

/// What a loaded model was loaded with, resolved: the device "auto" became,
/// the context the model defaults to where nothing overrode it. Compared to
/// decide whether a loaded model is still the one being asked for, which is
/// what makes a settings change reach the next turn — so it holds only what
/// changes how a runtime loads a model.
class LocalLoad {
  const LocalLoad({
    required this.contextLength,
    this.device,
    this.threads,
    this.keepsPrompts = false,
  });

  final int contextLength;

  /// The device in the runtime's own word, or null where the runtime has no
  /// choice of device.
  final String? device;

  final int? threads;

  /// Whether the model is loaded to save and restore its prompt state —
  /// llama.cpp changes how it stores its cache to do it, so for it this is
  /// part of the load. A runtime that keeps prompts the same way either way
  /// leaves it false, so the setting does not reload its models.
  final bool keepsPrompts;

  /// Every field, so one added is one compared.
  ({int c, String? d, int? t, bool k}) get _fields =>
      (c: contextLength, d: device, t: threads, k: keepsPrompts);

  @override
  bool operator ==(Object other) =>
      other is LocalLoad && other._fields == _fields;

  @override
  int get hashCode => _fields.hashCode;
}

/// One loaded model: what [Residency] keeps, [LocalClient] asks, and
/// [PromptCache] saves and restores. Each runtime has its own — a llama.cpp
/// server, an MLX model in the model host — and nothing above this class asks
/// which.
///
/// How far it has got is kept here, once, so every runtime's model reports a
/// load the same way: a runtime says when its model is [markReady] or has
/// [markFailed], and what loading and unloading are.
abstract class LocalInstance {
  LocalInstance(this.model, this.load, {required this._onChange});

  final DownloadedModel model;

  final LocalLoad load;

  /// Called as [state] moves, so the published list follows it.
  final void Function() _onChange;

  final _ready = Completer<void>();
  var _phase = LocalLlmPhase.starting;
  String? _failure;

  /// How far it has got, as the settings page draws it.
  LocalLlmState get state => LocalLlmState(
    modelId: model.id,
    phase: _phase,
    device: deviceLabel,
    contextLength: load.contextLength,
    failure: _failure,
  );

  /// The device in the picker's word, which is what reads [state].
  String? get deviceLabel => load.device;

  bool get failed => _phase == LocalLlmPhase.failed;

  /// Completes when it will answer, or fails with a [LocalLlmFailure] saying
  /// why it never will. Nothing completes it before [start].
  Future<void> get ready => _ready.future;

  /// Starts loading it. Separate from making it because [Residency] stops
  /// the models it displaces first: a load begun before they had gone would
  /// put two sets of weights in memory at once.
  void start();

  @protected
  void markReady() {
    if (_ready.isCompleted) return;
    _phase = LocalLlmPhase.ready;
    _ready.complete();
    _onChange();
  }

  /// Kept rather than cleared, so a turn sent at a model that will not load
  /// is told why instead of being told nothing is loaded. The row carries the
  /// reason alone — the settings page names the model above it — and the
  /// turn is told both.
  @protected
  void markFailed(String why) {
    _phase = LocalLlmPhase.failed;
    _failure = why;
    _abandon(LocalLlmFailure("${model.name} would not load: $why"));
    _onChange();
  }

  /// One model call. Where the runtime can say how far through the prompt it
  /// is, that arrives as `LlmPromptProgress` before the first token.
  Stream<LlmChunk> generate(
    List<LlmMessage> messages, {
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  });

  /// What makes one model's saved state unreadable by another, which the
  /// prompt cache files it under: the model, the context and device it loaded
  /// with, and [stateFormat]. NUL-separated, since no field can hold one.
  String get stateNamespace => [
    model.id,
    load.contextLength,
    load.device ?? "",
    stateFormat,
  ].join("\u0000");

  /// The kind of file [saveState] writes, so a runtime that changes it does
  /// not read the old kind back.
  @protected
  String get stateFormat;

  /// Writes the prompt state it holds to [path]. False where it could not,
  /// which is a miss to fall back from rather than an error.
  Future<bool> saveState(String path);

  /// Reads [path] back as the prompt state it holds. False where it could
  /// not.
  Future<bool> restoreState(String path);

  /// Never awaited past a moment: nothing waiting on this is waiting on the
  /// memory coming back. A load still under way is over, for whoever waits
  /// on [ready], before the model is let go.
  Future<void> stop() {
    _abandon(const LocalLlmFailure("The on-device model was stopped."));
    return unload();
  }

  /// Lets the model go.
  @protected
  Future<void> unload();

  /// Tell whoever is waiting that this attempt is over. [Future.ignore] is the
  /// half that is easy to forget: an error completed into a future nobody is
  /// waiting on is otherwise reported as unhandled, and usually nobody is.
  void _abandon(Object why) {
    if (_ready.isCompleted) return;
    _ready.completeError(why);
    _ready.future.ignore();
  }
}

/// What differs between the engines that run downloaded models: how a model
/// is loaded, and which settings mean anything to it. Everything else — which
/// models are resident, the turn, the prompt cache, the prefill — is
/// [LocalEngine]'s, written once.
abstract class LocalRuntime {
  const LocalRuntime();

  /// The settings this runtime reads, which is which rows the On-device page
  /// draws.
  Set<LocalControl> get controls;

  /// What [options] mean for [model] here: "auto" made a device, a default
  /// context made a number. Asynchronous because a runtime may have to ask the
  /// hardware what it has.
  Future<LocalLoad> resolve(DownloadedModel model, LocalOptions options);

  /// A new instance of [model], not yet loading. [onChange] is called as its
  /// state moves, so the published list follows it.
  LocalInstance create(
    DownloadedModel model,
    LocalLoad load, {
    required void Function() onChange,
  });

  /// The accelerators this device turned out to have, or null where the
  /// runtime offers no choice of device.
  Future<List<LocalDevice>>? devices() => null;

  /// The most cores worth offering a threads control, or null where there is
  /// no such control.
  int? get maxThreads => null;
}

/// Which settings an engine reads.
enum LocalControl {
  /// How many models may be resident at once.
  maxRunning,

  /// How much context a model is loaded with.
  context,

  /// Prompts kept warm on disk between turns.
  kvCache,

  /// The system prompt read in ahead of the first turn. Only where what the
  /// warm-up reads is a prefix the turn after it reuses — llama.cpp's slot,
  /// which matches tokens; MLX's session is carried on from by whole
  /// messages, which a warm-up's are not.
  prefill,
}
