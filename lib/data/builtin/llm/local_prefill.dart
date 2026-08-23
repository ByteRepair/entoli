import "dart:async";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "../../../domain/background_work.dart";
import "../../../domain/local_llm.dart";
import "../../../domain/local_model.dart";
import "llm_client.dart";
import "local_kv_cache.dart";
import "local_pool_client.dart";
import "openai_client.dart";

/// The whole of what to warm a model with, read together so the serve options
/// and the prompt cannot come from two different snapshots of the settings.
typedef Warmup = ({
  LocalPoolOptions options,
  List<LlmMessage> messages,
  List<LlmTool> tools,
});

/// Warms an on-device model's system-prompt KV before a chat needs it.
///
/// On-device only, and it changes nothing a hosted provider touches: it drives
/// the pool through the same [LocalLlm.serve] a turn does and the same
/// [OpenAiClient] the pool's own client builds, so no interface every provider
/// shares grew a method for this. What it adds is one background request whose
/// whole point is its prefix — [warmup] is the stable head of what a real turn
/// sends, so the server processes it into a slot and the chat that follows
/// reuses it rather than paying the whole prompt at once. See "Prefilling the
/// system prompt" in `lib/data/local/CLAUDE.md`.
class LocalPrefill {
  LocalPrefill({
    required this.llm,
    required this.background,
    required this.warmup,
    this.kvCache,
    this.httpClient,
  }) {
    // The Stop on its own notification.
    _stops = background.stopRequests
        .where((job) => job == BackgroundJob.prefill)
        .listen((_) => cancel());
  }

  final LocalLlm llm;
  final BackgroundWork background;
  final Warmup Function() warmup;

  /// What the warm-up's own client sends over. Injected only by the tests,
  /// which have no server to reach.
  final http.Client? httpClient;

  /// Where the warmed body is persisted, so it survives a reload and every
  /// chat's own `warm` finds it — the same cache a turn uses, null off Android.
  final LocalKvCache? kvCache;

  /// Which model is being warmed and how far it has got, or null when nothing
  /// is. A [ValueListenable] because the settings page draws it, beside the
  /// [LocalLlm.running] rows it lives next to.
  final ValueNotifier<LocalPrefillState?> state = ValueNotifier(null);

  /// The model being warmed, if any. Named so a request for the same one is a
  /// no-op and a request for another calls this one off first.
  String? _active;

  /// Bumped on every start and every cancel; a run whose number is no longer
  /// the current one has been superseded and stops where it notices.
  var _generation = 0;

  /// The warm-up request in flight, so a cancel can close it. Noticing the
  /// generation only happens on the next chunk, and while a prompt is being
  /// read that is however long the rest of it takes — minutes, which is the
  /// whole reason there is a Stop. Closing a finished one again does nothing,
  /// so it is left pointing at the last rather than cleared.
  OpenAiClient? _client;

  late final StreamSubscription<BackgroundJob> _stops;

  /// Warm [modelId], unless it is already the one being warmed. Cancels a warm
  /// of any other model first: the active default is the one to have ready, and
  /// two prefills would only evict each other in the pool's slots.
  Future<void> warm(String modelId) async {
    if (_active == modelId) return;
    await cancel();
    final gen = ++_generation;
    _active = modelId;
    await _run(modelId, gen);
    if (_generation == gen) await _clear();
  }

  /// Stop warming, if anything is. Leaves the pool as it is — whatever got into
  /// the cache before the stop stays there and is that much a real turn saves.
  Future<void> cancel() async {
    if (_active == null) return;
    _generation++;
    _client?.close();
    await _clear();
  }

  Future<void> _clear() async {
    _active = null;
    state.value = null;
    await background.prefilling(null);
  }

  Future<void> _run(String modelId, int gen) async {
    final name = localModelById(modelId)?.name ?? modelId;
    state.value = LocalPrefillState(name: name);
    await background.prefilling(name);

    // Armed before the serve rather than after it, so a model unloaded while it
    // is still coming up is noticed too. See [_whileServed].
    final unwatch = _whileServed(modelId, gen);
    try {
      await _warm(modelId, gen, name);
    } finally {
      unwatch();
    }
  }

  Future<void> _warm(String modelId, int gen, String name) async {
    final spec = warmup();
    final LocalEndpoint endpoint;
    try {
      endpoint = await llm.serve(
        modelId,
        device: spec.options.device,
        contextLength: spec.options.contextLength,
        maxRunning: spec.options.maxRunning,
        // The same flags a real turn serves with, or the first turn would find
        // the server launched differently and relaunch it, throwing this warm
        // away before anything reused it.
        threads: spec.options.threads,
        kvCache: spec.options.kvCacheOn,
      );
    } on LocalLlmFailure {
      // A model that will not load says so where a turn asks for it, not here:
      // the warm-up is silent, so its failure has to be too.
      return;
    }
    if (gen != _generation) return;

    final kv = kvLookup(
      kvCache,
      on: spec.options.kvCacheOn,
      modelId: modelId,
      at: endpoint,
      device: spec.options.device,
      messages: spec.messages,
      tools: spec.tools,
    );
    // An earlier run already wrote this body to disk, so restoring it is the
    // whole of the warm-up and there is nothing to read again. Without this the
    // cache only ever helped a chat, and every launch paid the prompt.
    try {
      if (kv != null &&
          await kv.cache.warm(endpoint, namespace: kv.namespace, keys: kv.keys)) {
        return;
      }
    } catch (_) {
      // A cache that will not answer leaves the prompt to be read below, which
      // is where this was before there was one.
    }

    final client = OpenAiClient(
      baseUrl: Uri.parse(endpoint.baseUrl),
      apiKey: endpoint.apiKey,
      returnProgress: true,
      httpClient: httpClient,
    );
    _client = client;
    try {
      await for (final chunk in client.stream(
        spec.messages,
        model: modelId,
        tools: spec.tools,
      )) {
        if (gen != _generation) break;
        if (chunk is LlmPromptProgress) {
          state.value = LocalPrefillState(name: name, fraction: chunk.fraction);
          continue;
        }
        // The first chunk that is not progress — a token, a tool call, the
        // completion — means the prompt has been read and is in the slot, which
        // is the whole of what the warm-up was for. Generating more would only
        // spend battery on output nobody reads.
        break;
      }
      // Persist the warmed body so it survives a reload — the disk half of what
      // the live slot already holds. The shortest key is the system+tools body
      // every chat shares. Best-effort, like the warm-up.
      if (gen == _generation && kv != null) {
        await kv.cache.keep(
          endpoint,
          namespace: kv.namespace,
          key: kv.keys.last,
          count: spec.options.kvCachePrompts,
        );
      }
    } catch (_) {
      // Best-effort: a warm-up that fails leaves the first real turn paying the
      // prompt the way it did before, which is the state this was improving on.
    } finally {
      client.close();
    }
  }

  /// Cancels the warm-up if the model it is warming leaves the pool, and
  /// answers with how to stop watching.
  ///
  /// **The invariant is here rather than at the button that broke it first.**
  /// Unload all is one way a warmed server goes; deleting a model is another
  /// (`unpick` stops everything), and a turn asking for a second model past
  /// `maxLocalModels` is a third, which no button could have known about. What
  /// they share is [LocalLlm.running] losing the row, and the pool publishes
  /// that before it kills anything.
  ///
  /// It fires only after the model has been seen running, since before the pool
  /// has published the row "not in the list" is a warm-up that has not started
  /// rather than one whose server has gone.
  VoidCallback _whileServed(String modelId, int gen) {
    var seen = false;
    void check() {
      if (llm.running.value.any((each) => each.modelId == modelId)) {
        seen = true;
      } else if (seen && gen == _generation) {
        unawaited(cancel());
      }
    }

    llm.running.addListener(check);
    return () => llm.running.removeListener(check);
  }

  void dispose() {
    _generation++;
    _client?.close();
    _stops.cancel();
    state.dispose();
  }
}

/// What [LocalPrefill] is doing, for the settings page to draw.
class LocalPrefillState {
  const LocalPrefillState({required this.name, this.fraction});

  /// The model's catalog name, since a notification and a settings row both
  /// read better as "Qwen3.5 2B" than as the id.
  final String name;

  /// How far the prompt has been read, or null before the first progress frame.
  final double? fraction;
}
