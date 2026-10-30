import "package:flutter/foundation.dart";

import "../../domain/app_settings.dart";
import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../builtin/llm/llm_client.dart";
import "../builtin/llm/local_kv_cache.dart";
import "../builtin/llm/local_pool_client.dart";
import "local_engine.dart";

/// llama.cpp's server, one process per model, over GGUF files: Android and
/// Linux. See "Running a model on the device" in `lib/data/local/AGENTS.md`.
class LlamaEngine extends LocalEngine {
  const LlamaEngine(this.llm, this.store, {this.kvCache});

  /// The server pool, which the prefill warms directly.
  final LocalLlm llm;

  @override
  final LocalModelStore store;

  /// Where a turn's KV is saved and restored, or null where none is kept.
  final LocalKvCache? kvCache;

  @override
  List<LocalModel> get catalog => ggufCatalog;

  @override
  Set<LocalControl> get controls => _controls;

  static final _controls = LocalControl.values.toSet();

  @override
  ValueListenable<List<LocalLlmState>> get running => llm.running;

  @override
  Future<void> stopAll() => llm.stopAll();

  @override
  LlmClient client(AppSettings Function() settings) =>
      LocalPoolClient(llm, () => poolOptions(settings()), kvCache: kvCache);

  @override
  Future<List<LocalDevice>> devices() => llm.devices();

  @override
  int? get maxThreads => llm.maxThreads;

  @override
  LocalModel Function(ModelLink link) get fromLink => (link) => GgufModel(
        id: link.id,
        name: link.name,
        url: link.url,
        parameters: link.parameters,
        licence: link.licence,
        sha256: link.sha256,
      );
}
