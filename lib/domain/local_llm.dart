import "package:flutter/foundation.dart";

import "app_settings.dart";
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
abstract class LocalLlm {
  const LocalLlm();

  /// Whether this build has a server to run at all. False in a browser and on
  /// the desktops, where an already-installed Ollama or LM Studio is the better
  /// answer and is two presets away — see `llmProviderPresets`.
  bool get available;

  /// What has been picked, and how far the server has got with it. A
  /// [ValueListenable] rather than a stream because the settings page draws it
  /// and a rebuild per frame of a model load is the wrong shape.
  ValueListenable<LocalLlmState> get state;

  /// The accelerators this device turned out to have, asked of the server
  /// itself. Empty means the CPU is all there is, which is the answer on most
  /// phones and every phone whose build carried no accelerated backend.
  ///
  /// Asked rather than declared: which backends were compiled in is a property
  /// of the build, which of them find hardware is a property of the phone, and
  /// only the binary knows both.
  Future<List<LocalDevice>> devices();

  /// Load [model] and serve it. Returns once the server has been started, not
  /// once it will answer: mapping a four-gigabyte model takes the better part
  /// of a minute, and the settings page has to be able to draw that rather than
  /// sit on an awaited dropdown. What waits for the end of it is [whenReady].
  Future<void> start(LocalModel model, {String? device, int? contextLength});

  Future<void> stop();

  /// Completes when the server will answer, or throws with why it never will.
  /// This is what the agent's client waits on, so a turn sent at a model that
  /// is still loading is a turn that waits rather than one that fails.
  Future<void> whenReady();

  /// The running server as an endpoint, or null when nothing is picked.
  ///
  /// Non-null from the moment a model is picked rather than from the moment it
  /// answers, so the model is in the picker while it loads — the alternative is
  /// a chat whose pinned model vanishes for the thirty seconds after a restart.
  LlmProviderConfig? get provider;
}

enum LocalLlmPhase { off, starting, ready, failed }

class LocalLlmState {
  const LocalLlmState({
    this.phase = LocalLlmPhase.off,
    this.modelId,
    this.device,
    this.contextLength,
    this.failure,
  });

  final LocalLlmPhase phase;

  /// The catalog id being served, which is also the model id the picker offers.
  final String? modelId;

  /// The device it was told to offload to, by name. Null is the CPU.
  final String? device;

  /// What it was loaded with. Held because it is one of the three things a
  /// change to means the server has to be started again, and comparing what is
  /// running against what is wanted is the whole of [applyLocalModel].
  final int? contextLength;

  /// Why it is not running, where [phase] is [LocalLlmPhase.failed]. It is the
  /// server's own last words, which for a model too large to fit is the only
  /// place that is said.
  final String? failure;

  bool get isRunning => phase == LocalLlmPhase.ready;
}

/// Start, stop or reload the server so that what is running is what
/// [settings] asks for.
///
/// One function rather than a rule each caller keeps, because there are two
/// callers and they are far apart: the settings page, where a model is picked,
/// and app startup, where a pick made in a previous run is honoured. Comparing
/// against what is already running is what makes it safe to call from either —
/// a launch with the right model already up does nothing, and re-picking the
/// model that failed to load tries it again.
Future<void> applyLocalModel(LocalLlm llm, AppSettings settings) async {
  if (!llm.available) return;
  final model = localModelById(settings.localModelId);
  if (model == null) return llm.stop();
  final running = llm.state.value;
  final same = running.modelId == model.id &&
      running.device == settings.localModelDevice &&
      running.contextLength == settings.localModelContext;
  // A failed one is deliberately not "the same": the pick being made again is
  // the user asking for another go at it, and there is nothing else they could
  // press to get one.
  if (same && running.phase != LocalLlmPhase.failed) return;
  await llm.start(
    model,
    device: settings.localModelDevice,
    contextLength: settings.localModelContext,
  );
}

/// The web's, and the desktops': no server bundled, so nothing to pick and
/// nothing in the provider list.
class UnavailableLocalLlm extends LocalLlm {
  const UnavailableLocalLlm();

  @override
  bool get available => false;

  @override
  ValueListenable<LocalLlmState> get state => _off;

  static final _off = ValueNotifier(const LocalLlmState());

  @override
  Future<List<LocalDevice>> devices() async => const [];

  @override
  Future<void> start(LocalModel model, {String? device, int? contextLength}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> whenReady() async =>
      throw StateError("There is no on-device model server in this build.");

  @override
  LlmProviderConfig? get provider => null;
}
