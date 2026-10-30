import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../builtin/llm/llm_client.dart";

/// How a model is to be loaded, as a turn asks for it. Read from the settings
/// fresh for every call, the way `LocalShell` re-reads its environment, so a
/// change reaches the next turn rather than the next launch.
///
/// What a runtime makes of it — the device "auto" resolves to, the context a
/// model defaults to — is [LocalLoad]; this is what was asked.
typedef LocalOptions = ({
  String? device,
  int? contextLength,
  int maxRunning,
  int? threads,
  int keptPrompts,
});

extension LocalOptionsKeeping on LocalOptions {
  /// Whether prompts are kept on disk between turns: the one place
  /// zero-means-off is read as a yes or no.
  bool get keepsPrompts => keptPrompts > 0;
}

/// What a loaded model was loaded with, resolved: the device "auto" became,
/// the context the model defaults to where nothing overrode it. Compared to
/// decide whether a loaded model is still the one being asked for, which is
/// what makes a settings change reach the next turn.
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

  /// Whether this load can save and restore its prompt state — llama.cpp
  /// changes how it stores its cache to do it, so it is part of the load.
  final bool keepsPrompts;

  @override
  bool operator ==(Object other) =>
      other is LocalLoad &&
      other.contextLength == contextLength &&
      other.device == device &&
      other.threads == threads &&
      other.keepsPrompts == keepsPrompts;

  @override
  int get hashCode => Object.hash(contextLength, device, threads, keepsPrompts);
}

/// One loaded model: what [Residency] keeps, [LocalClient] asks, and
/// [PromptCache] saves and restores. Each runtime has its own — a llama.cpp
/// server, an MLX model in the model host — and nothing above this class asks
/// which.
abstract class LocalInstance {
  DownloadedModel get model;

  LocalLoad get load;

  /// How far it has got, as the settings page draws it.
  LocalLlmState get state;

  /// Starts loading it. Separate from making it because [Residency] stops
  /// the models it displaces first: a load begun before they had gone would
  /// put two sets of weights in memory at once.
  void start();

  /// Completes when it will answer, or fails with a [LocalLlmFailure] saying
  /// why it never will. Nothing completes it before [start].
  Future<void> get ready;

  bool get failed => state.phase == LocalLlmPhase.failed;

  /// One model call. Where the runtime can say how far through the prompt it
  /// is, that arrives as `LlmPromptProgress` before the first token.
  Stream<LlmChunk> generate(
    List<LlmMessage> messages, {
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  });

  /// Writes the prompt state it holds to [file] in the prompt cache's
  /// directory. False where it could not, which is a miss to fall back from
  /// rather than an error.
  Future<bool> saveState(String file);

  /// Reads [file] back as the prompt state it holds. False where it could not.
  Future<bool> restoreState(String file);

  /// Never awaited past a moment: nothing waiting on this is waiting on the
  /// memory coming back.
  Future<void> stop();
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
}
