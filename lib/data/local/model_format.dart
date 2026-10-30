import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../../domain/local_model.dart";
import "gguf.dart";

/// What a model's files mean once they are on disk: where its runtime is
/// pointed, and the facts read off them. One per engine, handed to the store
/// that keeps that engine's models, so the store itself only fetches and
/// checks files.
abstract class ModelFormat {
  const ModelFormat();

  /// What the runtime loads, inside a model's [directory].
  String entry(String directory);

  /// The record for the model in [directory], read off its own files. [from]
  /// is what it was downloaded as, where that is known. Throws
  /// [FormatException] for files this format cannot run.
  DownloadedModel describe(String id, String directory, [LocalModel? from]);
}

/// One GGUF file, its facts read out of its header.
class GgufFormat extends ModelFormat {
  const GgufFormat();

  @override
  String entry(String directory) => p.join(directory, ggufWeights);

  @override
  DownloadedModel describe(String id, String directory, [LocalModel? from]) {
    final file = entry(directory);
    final facts = readGgufFacts(file);
    return DownloadedModel(
      id: id,
      name: (from?.name.isNotEmpty ?? false ? from!.name : null) ?? facts.name ?? id,
      file: file,
      bytes: File(file).lengthSync(),
      quantisation: facts.quantisation,
      contextLength: facts.contextLength,
      kvBytesPerToken: facts.kvBytesPerToken,
      parameters: from?.parameters,
      licence: from?.licence,
      url: from?.source,
    );
  }
}

/// A Hugging Face repository in MLX's layout, its facts read out of
/// `config.json`. The runtime is pointed at the directory itself.
class MlxFormat extends ModelFormat {
  const MlxFormat();

  @override
  String entry(String directory) => directory;

  @override
  DownloadedModel describe(String id, String directory, [LocalModel? from]) {
    final config = File(p.join(directory, "config.json"));
    if (!config.existsSync()) throw const FormatException("it has no config.json");
    final Object? json;
    try {
      json = jsonDecode(config.readAsStringSync());
    } on FormatException {
      throw const FormatException("its config.json is not JSON");
    }
    if (json is! Map) throw const FormatException("its config.json is not an object");
    // A model that also sees images keeps the language model's own numbers
    // under `text_config`.
    final text = json["text_config"] is Map ? json["text_config"] as Map : json;
    int? number(String key) => (text[key] as num?)?.toInt();

    final context = number("max_position_embeddings");
    final heads = number("num_attention_heads");
    final kvHeads = number("num_key_value_heads") ?? heads;
    final headDim = number("head_dim") ??
        switch ((number("hidden_size"), heads)) {
          (final hidden?, final heads?) when heads > 0 => hidden ~/ heads,
          _ => null,
        };
    // A hybrid's linear-attention layers keep no per-token cache.
    final layerTypes = text["layer_types"];
    final layers = layerTypes is List
        ? layerTypes.where((type) => type == "full_attention").length
        : number("num_hidden_layers");
    if (context == null || kvHeads == null || headDim == null || layers == null) {
      throw const FormatException("its config.json does not say what its context costs");
    }

    final bits = (json["quantization"] as Map?)?["bits"];
    return DownloadedModel(
      id: id,
      name: (from?.name.isNotEmpty ?? false) ? from!.name : id,
      file: entry(directory),
      bytes: _sizeOf(directory),
      quantisation: bits is int ? "$bits-bit" : "unquantised",
      contextLength: context,
      // K and V, f16, for every layer that has attention.
      kvBytesPerToken: layers * kvHeads * headDim * 2 * 2,
      parameters: from?.parameters,
      licence: from?.licence,
      url: from?.source,
    );
  }

  static int _sizeOf(String directory) => Directory(directory)
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => !p.basename(file.path).startsWith("."))
      .fold(0, (total, file) => total + file.lengthSync());
}
