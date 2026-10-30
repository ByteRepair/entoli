import "../../domain/local_model.dart";
import "local_engine.dart";

/// llama.cpp's server, one process per model, over GGUF files: Android and
/// Linux. See "Running a model on the device" in `lib/data/local/AGENTS.md`.
class LlamaEngine extends RuntimeEngine {
  LlamaEngine(super.runtime, super.store, {super.prompts});

  @override
  List<LocalModel> get catalog => ggufCatalog;

  @override
  LocalModel Function(ModelLink link) get fromLink =>
      (link) => GgufModel(
        id: link.id,
        name: link.name,
        url: link.url,
        parameters: link.parameters,
        licence: link.licence,
        sha256: link.sha256,
      );
}
