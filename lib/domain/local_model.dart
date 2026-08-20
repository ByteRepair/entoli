/// The models Entoli can run on the device itself, as data. `local_model_store.dart`
/// is what fetches one and `llama_server.dart` is what answers with it.
///
/// A const list for the reason `rootfs.dart` and `voice_model.dart` are ones: a
/// model Entoli can run is one someone checked the file of, so a new entry is a
/// line here rather than anything to discover. Sizes and checksums are exact,
/// so a row can say what it costs before it is fetched and the download can
/// refuse a file that is not the one that was checked.
library;

/// What a device can be asked to do the arithmetic on. The names are ggml's own
/// — a device is picked by passing its name to `--device`, and the CPU is the
/// one that is never named, since it is what runs when nothing is offloaded.
enum LocalCompute {
  cpu("CPU"),
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
    required this.licence,
    this.note,
  });

  /// Stable, and the name of the directory it installs into — renaming one
  /// orphans what a user already downloaded. It is also what the running server
  /// is told to call itself, so it is the model id that appears in the pickers
  /// and is written into a chat's `meta.json`.
  final String id;

  final String name;

  /// As the publisher writes it — `1.5B`. Shown rather than computed, since
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
  /// is what [LocalLlmOptions.contextLength] is for.
  final int contextLength;

  final String licence;

  /// Anything a row should say beyond its size. Null for the ones that need no
  /// warning.
  final String? note;
}

/// **Five, and all of them small.** A phone has the memory of a laptop from ten
/// years ago and no fan, so the ceiling here is about 4B parameters — beyond it
/// a model either will not fit beside Android or runs at a speed that makes the
/// agent loop unusable. The coder models are first because this is a coding
/// agent; the general ones are there because a small coder is bad at the
/// conversation around the code.
const localModelCatalog = <LocalModel>[
  LocalModel(
    id: "qwen2.5-coder-1.5b-q4_0",
    name: "Qwen2.5 Coder 1.5B Instruct",
    parameters: "1.5B",
    url: "https://huggingface.co/bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF/"
        "resolve/main/Qwen2.5-Coder-1.5B-Instruct-Q4_0.gguf",
    bytes: 937535776,
    sha256: "1165e56fbe4751906354a065e0d1d84e7db0352750929d6fe508fd0565f650a4",
    contextLength: 32768,
    licence: "Apache-2.0",
    note: "The one to try first: it fits on any phone that can run one at all.",
  ),
  LocalModel(
    id: "qwen2.5-coder-3b-q4_0",
    name: "Qwen2.5 Coder 3B Instruct",
    parameters: "3B",
    url: "https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF/"
        "resolve/main/Qwen2.5-Coder-3B-Instruct-Q4_0.gguf",
    bytes: 1828486400,
    sha256: "4a1bb431ec1095cc3c9c9741f1a9473841d9631adabf1839ef690376d4653938",
    contextLength: 32768,
    licence: "Qwen Research",
  ),
  LocalModel(
    id: "qwen3-1.7b-q4_0",
    name: "Qwen3 1.7B",
    parameters: "1.7B",
    url: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/"
        "resolve/main/Qwen3-1.7B-Q4_0.gguf",
    bytes: 1056782912,
    sha256: "c876f159707a4e4f70e045106c69db15bfc935a4981706fd4f65c6e7ea1e81c5",
    contextLength: 32768,
    licence: "Apache-2.0",
    note: "Thinks before it answers, which is slow on a phone and better at "
        "multi-step work when it can afford to be.",
  ),
  LocalModel(
    id: "qwen3-4b-2507-q4_0",
    name: "Qwen3 4B Instruct 2507",
    parameters: "4B",
    url: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/"
        "resolve/main/Qwen3-4B-Instruct-2507-Q4_0.gguf",
    bytes: 2375773280,
    sha256: "e0ba675d86ab277c61701c6793659b2ae801d95e3be791464c321e6fbf613be2",
    contextLength: 262144,
    licence: "Apache-2.0",
    note: "The best of these at using tools, and the one most likely to be "
        "killed for memory on a phone with 8 GB or less.",
  ),
  LocalModel(
    id: "llama-3.2-1b-q4_0",
    name: "Llama 3.2 1B Instruct",
    parameters: "1B",
    url: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/"
        "resolve/main/Llama-3.2-1B-Instruct-Q4_0.gguf",
    bytes: 773025920,
    sha256: "fa0390e7c043f89ae1847bd6682d748041a99d4ef3de0e0b27d33b6af97a8be8",
    contextLength: 131072,
    licence: "Llama 3.2 Community",
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
