import "dart:async";

import "package:flutter/foundation.dart";

import "../../../domain/background_work.dart";
import "../../../domain/local_llm.dart";
import "../../../domain/local_model.dart";
import "llm_client.dart";
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
  });

  final LocalLlm llm;
  final BackgroundWork background;
  final Warmup Function() warmup;

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

    final spec = warmup();
    final LocalEndpoint endpoint;
    try {
      endpoint = await llm.serve(
        modelId,
        device: spec.options.device,
        contextLength: spec.options.contextLength,
        maxRunning: spec.options.maxRunning,
      );
    } on LocalLlmFailure {
      // A model that will not load says so where a turn asks for it, not here:
      // the warm-up is silent, so its failure has to be too.
      return;
    }
    if (gen != _generation) return;

    final client = OpenAiClient(
      baseUrl: Uri.parse(endpoint.baseUrl),
      apiKey: endpoint.apiKey,
      returnProgress: true,
    );
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
    } catch (_) {
      // Best-effort: a warm-up that fails leaves the first real turn paying the
      // prompt the way it did before, which is the state this was improving on.
    } finally {
      client.close();
    }
  }

  void dispose() {
    _generation++;
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
