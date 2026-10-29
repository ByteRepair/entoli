/// The models Entoli can run on the device itself, as data. `local_model_store.dart`
/// is what fetches one and `llama_server.dart` is what answers with it.
///
/// Two lists that are not the same thing. [localModelCatalog] is what is
/// offered, each entry a download filled in ahead of time, sizes and checksums
/// exact so a row says what it costs and the download refuses a file that is
/// not the one that was checked. What is downloaded is a [DownloadedModel],
/// one per directory on disk, whatever it was fetched from: an entry here, a
/// link the user typed, or an entry an older build offered and this one does
/// not.
library;

/// What an accelerator is, for the label beside its name. There is no CPU here
/// deliberately: the CPU is what runs when nothing is offloaded, so ggml leaves
/// it out of `--list-devices` and there is no kind for it to have.
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

  /// The stored choice that forces the CPU when the phone does have an
  /// accelerator — distinct from a null choice, which is "use the best one
  /// found". Never a real device: ggml leaves the CPU out of `--list-devices`,
  /// so nothing it reports is named this. What the server is then passed is
  /// `noDevice`, which is llama.cpp's word rather than this one.
  static const cpu = "cpu";

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

/// One model to download, as one file: a catalog entry, or a link the user
/// typed. What it needs to run is read off the file once it has arrived, so
/// none of that is asked of either.
///
/// **The catalog is Q4_0 rather than the Q4_K_M everyone publishes**, and that
/// is the entry requirement rather than a preference. The Hexagon backend
/// repacks Q4_0, Q8_0 and MXFP4 and nothing else, so a K-quant is a model that
/// quietly runs on the CPU on the one device that has an NPU to run it on. A
/// link the user typed may be anything the server reads.
class LocalModel {
  const LocalModel({
    required this.id,
    required this.name,
    required this.url,
    this.parameters,
    this.bytes,
    this.sha256,
    this.licence,
  });

  /// Stable, and the name of the directory it installs into. It is also what
  /// the running server is told to call itself, so it is the model id that
  /// appears in the pickers and is written into a chat's `meta.json`.
  final String id;

  final String name;

  final String url;

  /// As the publisher writes it — `1.7B`. Shown rather than computed, since
  /// what a row is answering is "will this run on my phone".
  final String? parameters;

  /// What the server will send, exactly. The bar reads it before the first
  /// byte arrives; null takes the response's own length.
  final int? bytes;

  /// Checked before the file is kept, where one is given. Weights are not code,
  /// but they are a gigabyte fetched over somebody's mobile data and the
  /// publisher already says what they should be.
  final String? sha256;

  final String? licence;
}

/// A model on disk, described by its own file and by what it was fetched as.
class DownloadedModel {
  const DownloadedModel({
    required this.id,
    required this.name,
    required this.file,
    required this.bytes,
    required this.quantisation,
    required this.contextLength,
    required this.kvBytesPerToken,
    this.parameters,
    this.licence,
    this.url,
  });

  final String id;
  final String name;

  /// The weights, where the server is pointed.
  final String file;

  final int bytes;

  /// The GGUF's file type as llama.cpp names it — `Q4_0`.
  final String quantisation;

  /// What the model was trained to handle. Not what it is *run* with — a
  /// phone's memory is the KV cache's limit long before the model's is, which
  /// is what [defaultContext] and `AppSettings.localModelContext` are for.
  final int contextLength;

  /// What one token of context costs, resident, for the whole conversation:
  /// K and V for every layer with attention heads, f16, read off the GGUF's own
  /// metadata rather than worked out from the parameter count, which does not
  /// decide it. It is what makes [defaultContext] per model.
  final int kvBytesPerToken;

  final String? parameters;
  final String? licence;

  /// Where it came from; null for one an older build downloaded.
  final String? url;

  /// How much context this model is given when nothing overrides it.
  ///
  /// [kvBudgetBytes] divided by what a token costs, rounded down to a power of
  /// two and never past what the model was trained on — so the answer follows
  /// from the model's own architecture and needs no number invented for it.
  int get defaultContext {
    final affordable = kvBudgetBytes ~/ kvBytesPerToken;
    var context = 1024;
    while (context * 2 <= affordable && context * 2 <= contextLength) {
      context *= 2;
    }
    return context;
  }

  /// Whether an NPU can be handed it as it is; see [LocalModel].
  bool get offloadsToNpu => const {"Q4_0", "Q8_0", "MXFP4"}.contains(quantisation);

  Map<String, Object?> toJson() => {
        "id": id,
        "name": name,
        "bytes": bytes,
        "quantisation": quantisation,
        "contextLength": contextLength,
        "kvBytesPerToken": kvBytesPerToken,
        "parameters": ?parameters,
        "licence": ?licence,
        "url": ?url,
      };

  /// Null for anything that does not say what the server needs.
  static DownloadedModel? fromJson(Object? json, {required String file}) {
    if (json is! Map) return null;
    final id = json["id"], name = json["name"], bytes = json["bytes"];
    final quantisation = json["quantisation"];
    final context = json["contextLength"], kv = json["kvBytesPerToken"];
    if (id is! String || name is! String || bytes is! int || quantisation is! String ||
        context is! int || kv is! int || kv <= 0) {
      return null;
    }
    return DownloadedModel(
      id: id,
      name: name,
      file: file,
      bytes: bytes,
      quantisation: quantisation,
      contextLength: context,
      kvBytesPerToken: kv,
      parameters: json["parameters"] as String?,
      licence: json["licence"] as String?,
      url: json["url"] as String?,
    );
  }
}

/// What one running model's KV cache may take.
///
/// The weights are mapped and paged, so the file's size is not what decides
/// whether Android kills the app; the KV cache is resident, and it is. A
/// gigabyte is what leaves the smallest model a context worth having and
/// still fits beside the weights on a phone that can run them at all —
/// remembering that `maxLocalModels` lets two of these be resident at once, and
/// that this is the budget for each.
const kvBudgetBytes = 1024 * 1024 * 1024;

const _hf = "https://huggingface.co";

/// What is offered for download, smallest first, each the strongest at its
/// size that the bundled server runs: a phone of any size, one with 8 GB, and
/// one with 12. The Q4_0 of the third is bartowski's, since Ornith publishes
/// none.
const localModelCatalog = <LocalModel>[
  LocalModel(
    id: "lfm3-1.7b-q4_0",
    name: "LFM3 1.7B",
    parameters: "1.7B",
    url: "$_hf/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-QAD-Q4_0.gguf",
    bytes: 1049615680,
    sha256: "43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452",
    licence: "LFM Open License 1.0",
  ),
  LocalModel(
    id: "qwen3.5-4b-q4_0",
    name: "Qwen3.5 4B",
    parameters: "4B",
    url: "$_hf/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_0.gguf",
    bytes: 2583221408,
    sha256: "298fcb5fe7a77ccc79745ae24751560c5ac56874caff4bb39b1f2055bd72b8bb",
    licence: "Apache-2.0",
  ),
  LocalModel(
    id: "ornith-1.5-9b-q4_0",
    name: "Ornith-1.5 9B",
    parameters: "9B",
    url: "$_hf/bartowski/Ornith-1.5-9B-GGUF/resolve/main/Ornith-1.5-9B-Q4_0.gguf",
    bytes: 5482832768,
    sha256: "a5d329392574fd050af89231ca64eb004121ed51e373c441c4c748599f3cf489",
    licence: "MIT",
  ),
];

/// An id for a model downloaded from [url], unused by [taken]: the file's own
/// name without its extension, lower-cased, numbered past one in use.
String localModelIdFor(String url, Iterable<String> taken) {
  final file = Uri.tryParse(url)?.pathSegments.lastOrNull ?? "";
  final stem = file
      .replaceAll(RegExp(r"\.gguf$", caseSensitive: false), "")
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9._-]+"), "-")
      .replaceAll(RegExp(r"^[-.]+|[-.]+$"), "");
  final base = stem.isEmpty ? "model" : stem;
  final used = taken.toSet();
  if (!used.contains(base)) return base;
  for (var n = 2;; n++) {
    if (!used.contains("$base-$n")) return "$base-$n";
  }
}

/// The provider id the running server is offered under. Fixed rather than
/// configurable: it is written into a chat's `meta.json` beside the model, and
/// a chat that pinned one has to find it again on the next launch.
const localProviderId = "on-device";

/// The identifiers the Apple on-device model is offered under, in every
/// picker and in a chat's `meta.json` — for the same reason [localProviderId]
/// is fixed rather than configurable.
const appleProviderId = "apple-foundation";
const appleModelId = "apple-foundation-model";

/// Whether [modelId] at [providerId] may only name chats: the Apple system
/// model. Its 8,192-token window is mostly the agent's own prompt and tools —
/// about 6k before the first message — so every turn would open with a
/// compaction, and a sub-agent or a memory pass would fare no better; a title
/// is one short ask. A null model id is the provider's default, the system
/// model; the provider's MLX rows have windows of their own and are not this.
bool isTitleOnlyModel(String? providerId, String? modelId) =>
    providerId == appleProviderId && (modelId == null || modelId == appleModelId);
