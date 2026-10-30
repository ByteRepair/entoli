import "package:flutter/foundation.dart";

import "../../domain/app_settings.dart";
import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../builtin/llm/llm_client.dart";
import "local_client.dart";
import "local_instance.dart";
import "prompt_cache.dart";
import "residency.dart";

export "local_instance.dart" show LocalControl, LocalOptions;

/// What runs downloaded models on this device: the models it offers, where it
/// keeps them, what is loaded, and how a request reaches one. One per platform,
/// chosen in `core/platform/`, so nothing above it asks which engine it has —
/// the On-device page draws [catalog] and [controls], and the on-device
/// provider hands requests to [client].
abstract class LocalEngine {
  const LocalEngine();

  /// Whether this build can run a model at all.
  bool get available => true;

  /// Whether a build of this platform should have carried an engine and did
  /// not, which the On-device page says rather than leaving the section out.
  bool get missingFromBuild => false;

  /// What is offered for download.
  List<LocalModel> get catalog;

  LocalModelStore get store;

  Set<LocalControl> get controls;

  /// What is loaded and how far each one has got, least recently served first.
  ValueListenable<List<LocalLlmState>> get running;

  /// [modelId], loaded under [options] if it is not already: what a turn and
  /// the prefill reach a model through.
  Future<LocalInstance> serve(String modelId, LocalOptions options);

  /// Where prompts are kept between turns, or null where this build keeps
  /// none.
  PromptCache? get prompts => null;

  /// Unload [modelId], where it is loaded.
  Future<void> stop(String modelId);

  /// Unload everything.
  Future<void> stopAll();

  /// One client over every model this engine runs, the model named in a
  /// request deciding which. [settings] is read per request, so a change
  /// reaches the next turn.
  LlmClient client(AppSettings Function() settings);

  /// The ids of every model on disk. On disk rather than loaded: asking for one
  /// is what loads it.
  List<String> get installed => [
    for (final model in store.downloadedSync()) model.id,
  ];

  /// What [modelId] is called, for a line that names it.
  String nameOf(String modelId) =>
      store.downloadedOfSync(modelId)?.name ??
      catalog.where((m) => m.id == modelId).firstOrNull?.name ??
      modelId;

  /// The accelerators a model may be put on, or null where there is no choice
  /// to offer.
  Future<List<LocalDevice>>? devices() => null;

  /// The most cores worth offering, or null where cores are not this
  /// engine's to choose.
  int? get maxThreads => null;

  /// How a link the user typed becomes a model to download, or null where this
  /// engine takes none — which is also what draws Add model.
  LocalModel Function(ModelLink link)? get fromLink => null;
}

/// What the Add model page asks for.
typedef ModelLink = ({
  String url,
  String id,
  String name,
  String? parameters,
  String? licence,
  String? sha256,
});

/// An engine over a [LocalRuntime]: everything an engine does but load a model
/// — which models are resident, the turn, the prompt cache — written once, so
/// llama.cpp and MLX differ only in their runtime. See "The engine" in
/// `lib/data/local/AGENTS.md`.
abstract class RuntimeEngine extends LocalEngine {
  RuntimeEngine(this.runtime, this.store, {this.prompts})
    : residency = Residency(runtime, store);

  final LocalRuntime runtime;

  @override
  final LocalModelStore store;

  @override
  final PromptCache? prompts;

  final Residency residency;

  @override
  Set<LocalControl> get controls => runtime.controls;

  @override
  ValueListenable<List<LocalLlmState>> get running => residency.running;

  @override
  Future<LocalInstance> serve(String modelId, LocalOptions options) =>
      residency.serve(modelId, options);

  @override
  Future<void> stop(String modelId) => residency.stop(modelId);

  @override
  Future<void> stopAll() => residency.stopAll();

  @override
  LlmClient client(AppSettings Function() settings) =>
      LocalClient(residency, () => localOptions(settings()), prompts: prompts);

  @override
  Future<List<LocalDevice>>? devices() => runtime.devices();

  @override
  int? get maxThreads => runtime.maxThreads;
}

/// No engine: a platform with none, and a build that carried none.
class NoLocalEngine extends LocalEngine {
  const NoLocalEngine({this.missingFromBuild = false});

  @override
  final bool missingFromBuild;

  @override
  bool get available => false;

  @override
  List<LocalModel> get catalog => const [];

  @override
  LocalModelStore get store => const UnavailableLocalModelStore();

  @override
  Set<LocalControl> get controls => const {};

  @override
  ValueListenable<List<LocalLlmState>> get running => _none;

  static final _none = ValueNotifier(const <LocalLlmState>[]);

  @override
  Future<LocalInstance> serve(String modelId, LocalOptions options) =>
      Future.error(
        const LocalLlmFailure("This build runs no on-device models."),
      );

  @override
  Future<void> stop(String modelId) async {}

  @override
  Future<void> stopAll() async {}

  @override
  LlmClient client(AppSettings Function() settings) => const _NoClient();
}

class _NoClient implements LlmClient {
  const _NoClient();

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) =>
      Stream.error(const LlmException("This build runs no on-device models."));

  @override
  void close() {}
}
