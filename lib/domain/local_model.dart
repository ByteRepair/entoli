/// The models Entoli can run on the device itself, as data. `local_model_store.dart`
/// is what fetches one and `llama_server.dart` is what answers with it.
///
/// A const list for the reason `rootfs.dart` and `voice_model.dart` are ones: a
/// model Entoli can run is one someone checked the file of, so a new entry is a
/// line here rather than anything to discover. Sizes and checksums are exact,
/// so a row can say what it costs before it is fetched and the download can
/// refuse a file that is not the one that was checked.
library;

/// What an accelerator is, for the label beside its name. There is no CPU here
/// deliberately: the CPU is what runs when nothing is offloaded, so it is the
/// *absence* of a device rather than one of them — which is why `--device` is
/// passed nothing to get it, and why the picker's CPU entry carries a null.
enum LocalCompute {
  gpu("GPU"),
  npu("NPU");

  const LocalCompute(this.label);

  final String label;
}

/// One accelerator the bundled server reported, as it named it.
///
/// Discovered rather than declared: which backends a build carried and which of
/// them find hardware on *this* phone is a question only the binary can answer,
/// and the answer differs between two devices of the same ABI. See
/// [LocalLlm.devices].
class LocalDevice {
  const LocalDevice({
    required this.name,
    required this.description,
    required this.compute,
    this.totalBytes,
  });

  /// What `--device` takes, e.g. `HTP0` or `Vulkan0`.
  final String name;

  /// The hardware behind it, in the backend's own words.
  final String description;

  final LocalCompute compute;

  /// What the backend says it has, where it says anything.
  final int? totalBytes;

  /// Which of the three a device name belongs to. Read off the name because
  /// that is all `--list-devices` guarantees: the description is the vendor's
  /// prose and has no shape worth parsing.
  ///
  /// Anything unrecognised is a [LocalCompute.gpu], which is what every ggml
  /// accelerator but Hexagon is — and is the harmless way round to be wrong,
  /// since the label is all this decides.
  static LocalCompute computeOf(String name) =>
      name.startsWith("HTP") ? LocalCompute.npu : LocalCompute.gpu;
}

/// One model, as one file.
///
/// **Q4_0 rather than the Q4_K_M everyone publishes**, and that is the entry
/// requirement rather than a preference. The Hexagon backend repacks Q4_0, Q8_0
/// and MXFP4 and nothing else, so a K-quant is a model that quietly runs on the
/// CPU on the one device that has an NPU to run it on. Q4_0 is a little worse
/// per byte and is the only one of the two that can be offloaded.
class LocalModel {
  const LocalModel({
    required this.id,
    required this.name,
    required this.parameters,
    required this.url,
    required this.bytes,
    required this.sha256,
    required this.contextLength,
    required this.kvBytesPerToken,
    required this.licence,
    this.note,
  });

  /// Stable, and the name of the directory it installs into — renaming one
  /// orphans what a user already downloaded. It is also what the running server
  /// is told to call itself, so it is the model id that appears in the pickers
  /// and is written into a chat's `meta.json`.
  final String id;

  final String name;

  /// As the publisher writes it — `0.8B`. Shown rather than computed, since
  /// what a row is answering is "will this run on my phone".
  final String parameters;

  final String url;

  /// What the server will send, exactly. The bar reads it before the first byte
  /// arrives, and a `Content-Length` that disagrees is not treated as news.
  final int bytes;

  /// Checked before the file is kept. Weights are not code, but they are a
  /// gigabyte fetched over somebody's mobile data and the publisher already
  /// says what they should be.
  final String sha256;

  /// What the model was trained to handle. Not what it is *run* with — a
  /// phone's memory is the KV cache's limit long before the model's is, which
  /// is what [defaultContext] and `AppSettings.localModelContext` are for.
  final int contextLength;

  /// What one token of context costs, resident, for the whole conversation.
  ///
  /// `2 × block_count × head_count_kv × key_length × 2` — K and V, every layer,
  /// f16 — read off each GGUF's own metadata rather than worked out from the
  /// parameter count, which does not decide it. It is what makes [defaultContext]
  /// per model instead of one number for a catalog whose entries differ by 2.7×.
  final int kvBytesPerToken;

  /// How much context this model is given when nothing overrides it.
  ///
  /// [kvBudgetBytes] divided by what a token costs, rounded down to a power of
  /// two — so the answer follows from the model's own architecture and a new
  /// catalog entry needs no number invented for it.
  int get defaultContext {
    final affordable = kvBudgetBytes ~/ kvBytesPerToken;
    var context = 1024;
    while (context * 2 <= affordable) {
      context *= 2;
    }
    return context;
  }

  final String licence;

  /// Anything a row should say beyond its size. Null for the ones that need no
  /// warning.
  final String? note;
}

/// What one running model's KV cache may take.
///
/// The weights are mapped and paged, so the file's size is not what decides
/// whether Android kills the app; the KV cache is resident, and it is. A
/// gigabyte is what leaves the two smaller models a context worth having and
/// still fits beside the weights on a phone that can run them at all —
/// remembering that `maxLocalModels` lets two of these be resident at once, and
/// that this is the budget for each.
const kvBudgetBytes = 1024 * 1024 * 1024;

const _unsloth = "https://huggingface.co/unsloth";

/// Four sizes of one model, smallest useful first. The ceiling moved with this
/// list — a 9B is reachable on a phone with 12 GB, where the last one stopped
/// at about 4B — so the top of it is a real pick on some devices and a refusal
/// to load on others, which is what the notes are for.
const localModelCatalog = <LocalModel>[
  LocalModel(
    id: "qwen3.5-2b-q4_0",
    name: "Qwen3.5 2B",
    parameters: "2B",
    url: "$_unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_0.gguf",
    bytes: 1214873856,
    sha256: "cd70221bebaee0503e0f6717e174250cd7825aa88438b3aabec9ad55731d9bb1",
    contextLength: 262144,
    kvBytesPerToken: 49152,
    licence: "Apache-2.0",
    note: "The one to try first: it fits on any phone that can run one at all, "
        "and it answers rather than thinking first.",
  ),
  LocalModel(
    id: "qwen3.5-4b-q4_0",
    name: "Qwen3.5 4B",
    parameters: "4B",
    url: "$_unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_0.gguf",
    bytes: 2583221408,
    sha256: "298fcb5fe7a77ccc79745ae24751560c5ac56874caff4bb39b1f2055bd72b8bb",
    contextLength: 262144,
    kvBytesPerToken: 131072,
    licence: "Apache-2.0",
    note: "The pick on a phone with 8 GB or more. It thinks before it answers, "
        "which is slow here and is most of why it is better at a long turn.",
  ),
  LocalModel(
    id: "qwen3.5-9b-q4_0",
    name: "Qwen3.5 9B",
    parameters: "9B",
    url: "$_unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_0.gguf",
    bytes: 5379417312,
    sha256: "17670346b4260ddcb0173965145155885024f3c9a4a24389a3370751edbcde24",
    contextLength: 262144,
    kvBytesPerToken: 131072,
    licence: "Apache-2.0",
    note: "The best of these at code and at using tools, and five gigabytes of "
        "a phone that had better have 12.",
  ),
  LocalModel(
    id: "qwen3.5-0.8b-q4_0",
    name: "Qwen3.5 0.8B",
    parameters: "0.8B",
    url: "$_unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_0.gguf",
    bytes: 507154688,
    sha256: "444406ddd926550c724ec18d5120a9d40ded44908a063b0e66e9a7e5464c652c",
    contextLength: 262144,
    kvBytesPerToken: 49152,
    licence: "Apache-2.0",
    note: "Small enough to be a check that the NPU works at all, and too small "
        "to be much good at the agent's own job.",
  ),
];

LocalModel? localModelById(String? id) {
  for (final model in localModelCatalog) {
    if (model.id == id) return model;
  }
  return null;
}

/// The provider id the running server is offered under. Fixed rather than
/// configurable: it is written into a chat's `meta.json` beside the model, and
/// a chat that pinned one has to find it again on the next launch.
const localProviderId = "on-device";
