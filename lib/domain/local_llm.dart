import "package:flutter/foundation.dart";

import "llm_provider.dart";
import "local_model.dart";

/// A model answering from the device itself, with nothing on the other end of
/// the network.
///
/// **It is a provider like any other, and that is the whole design.** What runs
/// on the phone is llama.cpp's own server, bound to the loopback address and
/// speaking the `/chat/completions` shape Entoli already has a client for — so
/// a local model reaches the agent through `LlmRegistry`, `OpenAiClient` and
/// the model picker unchanged, and everything the agent can do with a hosted
/// model it can do with this one. Tool calls included, which is what rules out
/// the alternative of binding libllama through FFI: parsing a small model's
/// idea of a tool call out of its chat template is most of what the server is
/// for, and none of it is worth writing twice.
///
/// **It is a pool rather than one server.** Every model on disk is offered, and
/// one is loaded when a turn actually asks for it — see "Loading one, and when"
/// in `lib/data/local/AGENTS.md`.
abstract class LocalLlm {
  const LocalLlm();

  /// Whether this build has a server to run at all. False in a browser and on
  /// the desktops, where an already-installed Ollama or LM Studio is the better
  /// answer and is two presets away — see `llmProviderPresets`.
  bool get available;

  /// What is loaded and how far each one has got, least recently served first.
  /// A [ValueListenable] rather than a stream because the settings page draws
  /// it and a rebuild per frame of a model load is the wrong shape.
  ValueListenable<List<LocalLlmState>> get running;

  /// The accelerators this device turned out to have, asked of the server
  /// itself. Empty means the CPU is all there is, which is the answer on most
  /// phones and every phone whose build carried no accelerated backend.
  ///
  /// Asked rather than declared: which backends were compiled in is a property
  /// of the build, which of them find hardware is a property of the phone, and
  /// only the binary knows both.
  Future<List<LocalDevice>> devices();

  /// Where to reach [modelId], loading it first if it is not up.
  ///
  /// Completes when the server will answer — mapping a model takes the better
  /// part of a minute — or throws [LocalLlmFailure] with the server's own last
  /// words when it never will. A model already up under these settings is
  /// returned untouched; one up under different ones is loaded again, which is
  /// what makes this the only thing reconciling the running servers with the
  /// settings. There is no second path to forget.
  ///
  /// [maxRunning] is the cap: asking for one past it stops the least recently
  /// served first. Settings are passed per call rather than held, the way
  /// `LocalShell` re-reads its environment, so a change in settings reaches the
  /// next turn rather than the next launch.
  Future<LocalEndpoint> serve(
    String modelId, {
    String? device,
    int? contextLength,
    int maxRunning = 1,
    int? threads,
    bool kvCache = false,
  });

  /// The most cores worth offering the [threads] control, or null where there
  /// is no server to run on. It is the big-core count (`bigCoreCount`) the
  /// server would use by default, so the slider tops out at what it already
  /// does rather than at a number that would only slow it down.
  int? get maxThreads;

  /// Stop everything. What the settings page's own control reaches, and what a
  /// phone short of memory wants.
  Future<void> stopAll();

  /// The ids of every model on disk. What is *on disk* rather than what is
  /// loaded: asking for one is what causes it to load, so a list of the
  /// already-running would never grow.
  List<String> get installed;

  /// [installed], as one provider. Null where nothing is downloaded, which is
  /// what keeps the entry out of every picker until there is something to pick.
  LlmProviderConfig? get provider;
}

/// One running server: where it is, and what it will answer to.
///
/// Together rather than apart because they are made together and mean nothing
/// singly — the key is generated per launch and is the whole of what stops
/// another app on the phone spending this model's battery.
class LocalEndpoint {
  const LocalEndpoint({
    required this.baseUrl,
    required this.apiKey,
    required this.contextLength,
  });

  final String baseUrl;
  final String apiKey;

  /// The context the server actually loaded with — the model's own default
  /// unless something overrode it. Carried here so the KV cache keys a dump on
  /// the context the server is running rather than resolving it a second time
  /// and risking a namespace the server never writes into.
  final int contextLength;
}

enum LocalLlmPhase { starting, ready, failed }

/// One model in the pool, and how far it has got.
class LocalLlmState {
  const LocalLlmState({
    required this.modelId,
    required this.phase,
    this.device,
    this.contextLength,
    this.failure,
  });

  /// The catalog id being served, which is also the model id the picker offers.
  final String modelId;

  final LocalLlmPhase phase;

  /// The device it ended up on, named the way the picker names one — so
  /// [LocalDevice.cpu] where it offloads nothing. Resolved rather than chosen:
  /// this is what the auto setting turned out to mean, which is the one thing
  /// the picker cannot show.
  final String? device;

  /// What it was loaded with. Held because it is what a later [LocalLlm.serve]
  /// compares against to decide whether this server is still the one being
  /// asked for.
  final int? contextLength;

  /// Why it is not running, where [phase] is [LocalLlmPhase.failed]. It is the
  /// server's own last words, which for a model too large to fit is the only
  /// place that is said.
  final String? failure;
}

/// Why the model is not answering, worded by the server. Its own type so the
/// agent's error arm can say "the on-device model" rather than reporting a
/// connection to localhost that was refused.
class LocalLlmFailure implements Exception {
  const LocalLlmFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How many models may be resident at once, and what the settings page offers.
///
/// Two is the ceiling rather than a number to type: each is its own process
/// with its own weights and its own [kvBudgetBytes] of KV cache, and a phone
/// that could hold three of those is not the phone this is written for. Two is
/// worth having because the pair is not symmetric — a small model naming chats
/// beside a large one answering them costs far less than the large one twice.
const maxLocalModelsAllowed = 2;

/// The web's, and the desktops': no server bundled, so nothing to load and
/// nothing in the provider list.
class UnavailableLocalLlm extends LocalLlm {
  const UnavailableLocalLlm();

  @override
  bool get available => false;

  @override
  ValueListenable<List<LocalLlmState>> get running => _none;

  static final _none = ValueNotifier(const <LocalLlmState>[]);

  @override
  Future<List<LocalDevice>> devices() async => const [];

  @override
  Future<LocalEndpoint> serve(
    String modelId, {
    String? device,
    int? contextLength,
    int maxRunning = 1,
    int? threads,
    bool kvCache = false,
  }) async =>
      throw const LocalLlmFailure("There is no on-device model server in this build.");

  @override
  int? get maxThreads => null;

  @override
  Future<void> stopAll() async {}

  @override
  List<String> get installed => const [];

  @override
  LlmProviderConfig? get provider => null;
}
