import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;
import "package:entoli_core/model/local_model.dart";
import "package:entoli_core/model/memory_plan.dart";

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

  /// What it was downloaded as, unless that was left blank.
  static String? nameFrom(LocalModel? from) =>
      (from?.name.isEmpty ?? true) ? null : from!.name;
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
      name: ModelFormat.nameFrom(from) ?? facts.name ?? id,
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
    final config = MlxConfig.read(directory);
    return DownloadedModel(
      id: id,
      name: ModelFormat.nameFrom(from) ?? id,
      file: entry(directory),
      bytes: from?.bytes ?? _sizeOf(directory),
      quantisation: config.quantisation,
      contextLength: config.context,
      kvBytesPerToken: config.kvBytesPerToken,
      parameters: from?.parameters,
      licence: from?.licence,
      url: from?.source,
    );
  }

  /// What [model] costs in memory once loaded: its weights, and the rest of
  /// its config beside what [describe] recorded. Throws [FormatException]
  /// where the files are not there to read.
  static ModelShape shapeOf(DownloadedModel model) {
    try {
      final weights = _sizeOf(
        model.file,
        where: (file) => file.path.endsWith(".safetensors"),
      );
      return MlxConfig.read(
        model.file,
      ).shape(model, weightBytes: weights > 0 ? weights : model.bytes);
    } on FileSystemException catch (e) {
      throw FormatException("its files could not be read: ${e.message}");
    }
  }

  static int _sizeOf(String directory, {bool Function(File)? where}) =>
      Directory(directory)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => !p.basename(file.path).startsWith("."))
          .where(where ?? (_) => true)
          .fold(0, (total, file) => total + file.lengthSync());
}

/// A model's `config.json`, the language model's own numbers: a model that
/// also sees images keeps them under `text_config`. Read once, every number
/// parsed as it is.
class MlxConfig {
  MlxConfig._({
    required this.context,
    required this.kvBytesPerToken,
    required this.quantisation,
    required this._stateBytes,
    required this._heads,
    required this._headDim,
    required this._hiddenSize,
    required this._intermediateSize,
  });

  /// Throws [FormatException] for a directory with no config to read.
  factory MlxConfig.read(String directory) {
    final file = File(p.join(directory, "config.json"));
    if (!file.existsSync()) {
      throw const FormatException("it has no config.json");
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException {
      throw const FormatException("its config.json is not JSON");
    }
    if (json is! Map) {
      throw const FormatException("its config.json is not an object");
    }
    final text = json["text_config"] is Map ? json["text_config"] as Map : json;
    int? number(String key) => switch (text[key]) {
      final num n => n.toInt(),
      _ => null,
    };

    final context = number("max_position_embeddings");
    final heads = number("num_attention_heads");
    final kvHeads = number("num_key_value_heads") ?? heads;
    final hidden = number("hidden_size");
    final headDim =
        number("head_dim") ??
        switch ((hidden, heads)) {
          (final hidden?, final heads?) when heads > 0 => hidden ~/ heads,
          _ => null,
        };
    final types = text["layer_types"] is List
        ? text["layer_types"] as List
        : null;
    int layersOf(String type) => types?.where((t) => t == type).length ?? 0;
    // A hybrid's linear-attention layers keep no per-token cache.
    final layers = types == null
        ? number("num_hidden_layers")
        : layersOf("full_attention");
    if (context == null ||
        kvHeads == null ||
        headDim == null ||
        layers == null) {
      throw const FormatException(
        "its config.json does not say what its context costs",
      );
    }

    // A linear-attention layer's recurrent state, f32, and its convolution's
    // last few inputs, f16: the same size whatever the conversation.
    final keyHeads = number("linear_num_key_heads") ?? 0;
    final valueHeads = number("linear_num_value_heads") ?? 0;
    final keyDim = number("linear_key_head_dim") ?? 0;
    final valueDim = number("linear_value_head_dim") ?? 0;
    final kernel = number("linear_conv_kernel_dim") ?? 1;
    final recurrent = valueHeads * keyDim * valueDim * 4;
    final convolution =
        (kernel - 1) * (2 * keyHeads * keyDim + valueHeads * valueDim) * 2;

    final bits = (json["quantization"] as Map?)?["bits"];
    return MlxConfig._(
      context: context,
      // K and V, f16, for every layer that has attention.
      kvBytesPerToken: layers * kvHeads * headDim * 2 * 2,
      quantisation: bits is int ? "$bits-bit" : "unquantised",
      stateBytes: layersOf("linear_attention") * (recurrent + convolution),
      heads: heads ?? kvHeads,
      headDim: headDim,
      hiddenSize: hidden ?? 0,
      intermediateSize: number("intermediate_size") ?? 0,
    );
  }

  final int context;
  final int kvBytesPerToken;
  final String quantisation;
  final int _stateBytes;
  final int _heads;
  final int _headDim;
  final int _hiddenSize;
  final int _intermediateSize;

  /// The shape [model] was described with, and the numbers only a plan reads.
  ModelShape shape(DownloadedModel model, {required int weightBytes}) =>
      ModelShape(
        weightBytes: weightBytes,
        kvBytesPerToken: model.kvBytesPerToken,
        trainedContext: model.contextLength,
        stateBytes: _stateBytes,
        attentionHeads: _heads,
        headDim: _headDim,
        hiddenSize: _hiddenSize,
        intermediateSize: _intermediateSize,
      );
}
