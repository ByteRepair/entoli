/// The models Entoli can run on the device itself, as data. `local_model_store.dart`
/// is what fetches one and `llama_server.dart` is what answers with it.
///
/// Two lists that are not the same thing. An engine's catalog ([ggufCatalog])
/// is what is offered, each entry a download filled in ahead of time, sizes and checksums
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

/// One file of a model to download, and where it lands in the model's
/// directory.
class ModelFile {
  const ModelFile({
    required this.path,
    required this.url,
    this.bytes,
    this.sha256,
  });

  /// Relative to the model's directory.
  final String path;

  final String url;

  /// What the server will send, exactly. The bar reads it before the first
  /// byte arrives; null takes the response's own length.
  final int? bytes;

  /// Checked before the file is kept, where one is given. Weights are not code,
  /// but they are a gigabyte fetched over somebody's mobile data and the
  /// publisher already says what they should be.
  final String? sha256;
}

/// One model to download: a catalog entry, or a link the user typed. What it
/// needs to run is read off its files once they have arrived, so none of that
/// is asked of either. Which files make a model is the format's: see
/// [GgufModel].
abstract class LocalModel {
  const LocalModel({
    required this.id,
    required this.name,
    this.parameters,
    this.licence,
  });

  /// Stable, and the name of the directory it installs into. It is also what
  /// the running server is told to call itself, so it is the model id that
  /// appears in the pickers and is written into a chat's `meta.json`.
  final String id;

  final String name;

  /// As the publisher writes it — `1.7B`. Shown rather than computed, since
  /// what a row is answering is "will this run on my phone".
  final String? parameters;

  final String? licence;

  List<ModelFile> get files;

  /// Where it came from, recorded beside the download.
  String? get source;

  /// The whole download, or null where a file does not say.
  int? get bytes {
    var total = 0;
    for (final file in files) {
      final size = file.bytes;
      if (size == null) return null;
      total += size;
    }
    return total;
  }
}

/// Where a GGUF's weights land in its directory, whatever they were published
/// as.
const ggufWeights = "model.gguf";

/// A model that is one GGUF file, which is what llama.cpp runs.
///
/// **The catalog is Q4_0 rather than the Q4_K_M everyone publishes**, and that
/// is the entry requirement rather than a preference. The Hexagon backend
/// repacks Q4_0, Q8_0 and MXFP4 and nothing else, so a K-quant is a model that
/// quietly runs on the CPU on the one device that has an NPU to run it on. A
/// link the user typed may be anything the server reads.
class GgufModel extends LocalModel {
  const GgufModel({
    required super.id,
    required super.name,
    required this.url,
    super.parameters,
    this.size,
    this.sha256,
    super.licence,
  });

  final String url;
  final int? size;
  final String? sha256;

  @override
  List<ModelFile> get files =>
      [ModelFile(path: ggufWeights, url: url, bytes: size, sha256: sha256)];

  @override
  String get source => url;
}

/// A model already on disk that no catalog offers: an older catalog's entry,
/// or one added by link in an earlier session. There is nothing to fetch, only
/// a row to delete.
class OnDiskModel extends LocalModel {
  const OnDiskModel({required super.id, required super.name, this.source});

  @override
  List<ModelFile> get files => const [];

  @override
  final String? source;
}

/// A model in MLX's layout: a Hugging Face repository's files at one pinned
/// revision, of which [weights] names the ones loading needs. The rest — the
/// README, the images, a vision model's preprocessors — are never fetched.
class MlxModel extends LocalModel {
  const MlxModel({
    required super.id,
    required super.name,
    required this.repo,
    required this.revision,
    required this.weights,
    super.parameters,
    super.licence,
  });

  final String repo;

  /// A commit, never a branch: the checksums below are this commit's.
  final String revision;

  final List<(String path, int bytes, String sha256)> weights;

  @override
  List<ModelFile> get files => [
        for (final (path, bytes, sha256) in weights)
          ModelFile(
            path: path,
            url: "$_hf/$repo/resolve/$revision/$path",
            bytes: bytes,
            sha256: sha256,
          ),
      ];

  @override
  String get source => "$_hf/$repo";
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

/// What llama.cpp is offered, smallest first, each the strongest at its
/// size that the bundled server runs: a phone of any size, one with 8 GB, and
/// one with 12. The Q4_0 of the third is bartowski's, since Ornith publishes
/// none.
const ggufCatalog = <GgufModel>[
  GgufModel(
    id: "lfm3-1.7b-q4_0",
    name: "LFM3 1.7B",
    parameters: "1.7B",
    url: "$_hf/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-QAD-Q4_0.gguf",
    size: 1049615680,
    sha256: "43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452",
    licence: "LFM Open License 1.0",
  ),
  GgufModel(
    id: "qwen3.5-4b-q4_0",
    name: "Qwen3.5 4B",
    parameters: "4B",
    url: "$_hf/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_0.gguf",
    size: 2583221408,
    sha256: "298fcb5fe7a77ccc79745ae24751560c5ac56874caff4bb39b1f2055bd72b8bb",
    licence: "Apache-2.0",
  ),
  GgufModel(
    id: "ornith-1.5-9b-q4_0",
    name: "Ornith-1.5 9B",
    parameters: "9B",
    url: "$_hf/bartowski/Ornith-1.5-9B-GGUF/resolve/main/Ornith-1.5-9B-Q4_0.gguf",
    size: 5482832768,
    sha256: "a5d329392574fd050af89231ca64eb004121ed51e373c441c4c748599f3cf489",
    licence: "MIT",
  ),
];

/// What MLX is offered: the same three sizes as [ggufCatalog], in MLX's 4-bit
/// format, each a model mlx-swift-lm has an architecture for. LFM3 has none
/// there, so the smallest is Qwen3.5 2B, the nearest of its size that calls
/// tools. The 9B is Ornith's own conversion.
const mlxCatalog = <MlxModel>[
  MlxModel(
    id: "qwen3.5-2b-mlx-4bit",
    name: "Qwen3.5 2B",
    parameters: "2B",
    repo: "mlx-community/Qwen3.5-2B-4bit",
    revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
    licence: "Apache-2.0",
    weights: [
      ("chat_template.jinja", 7755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
      ("config.json", 3113, "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"),
      ("model.safetensors", 1722271785, "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
      ("model.safetensors.index.json", 81722, "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d"),
      ("tokenizer.json", 19989343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
      ("tokenizer_config.json", 1139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
    ],
  ),
  MlxModel(
    id: "qwen3.5-4b-mlx-4bit",
    name: "Qwen3.5 4B",
    parameters: "4B",
    repo: "mlx-community/Qwen3.5-4B-4bit",
    revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
    licence: "Apache-2.0",
    weights: [
      ("chat_template.jinja", 7756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
      ("config.json", 3366, "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
      ("model.safetensors", 3034300695, "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
      ("model.safetensors.index.json", 101944, "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
      ("tokenizer.json", 19989343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
      ("tokenizer_config.json", 1139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
    ],
  ),
  MlxModel(
    id: "ornith-1.5-9b-mlx-4bit",
    name: "Ornith-1.5 9B",
    parameters: "9B",
    repo: "ornith-ai/Ornith-1.5-9B-MLX-4bit",
    revision: "a48173b246ac705be75c05bedf1a0666db522d53",
    licence: "MIT",
    weights: [
      ("chat_template.jinja", 7593, "9dd2fbd270feaa1fbef2d4f634d7887c9c506e3bde140f8e7351c8944e8fd235"),
      ("config.json", 3084, "7ddc5bb8c3057edaa0a3337c1721312a8f3d28ad587b77dd6ac075876929d95d"),
      ("model.safetensors", 5038161163, "c022a4c4b8de62c75306e2442fd78161ff49bce85fe7abb308c5ad5d04454a26"),
      ("model.safetensors.index.json", 81194, "215f9abadc1cea4d465b01c036dffcac5a84c2fb2386777863eff6928b91ed0b"),
      ("tokenizer.json", 19989325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
      ("tokenizer_config.json", 1160, "386ba246ba3dfa4d3a21d8bc8712eba38de558e5ac94c2c90436d8f94d519d5e"),
    ],
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
/// model.
bool isTitleOnlyModel(String? providerId, String? modelId) =>
    providerId == appleProviderId && (modelId == null || modelId == appleModelId);
