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

  /// What [model], in its [directory], costs in memory once loaded.
  static ModelShape shapeOf(DownloadedModel model) {
    final config = MlxConfig.read(model.file);
    final weights = Directory(model.file)
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith(".safetensors"))
        .fold(0, (total, file) => total + file.lengthSync());
    return config.shape(weights > 0 ? weights : model.bytes);
  }

  static int _sizeOf(String directory) => Directory(directory)
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => !p.basename(file.path).startsWith("."))
      .fold(0, (total, file) => total + file.lengthSync());
}

/// A model's `config.json`, the language model's own numbers: a model that
/// also sees images keeps them under `text_config`.
class MlxConfig {
  MlxConfig._(this._json, this._text);

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
    final config = MlxConfig._(json, text);
    if (config._context == null ||
        config._kvHeads == null ||
        config._headDim == null ||
        config._attentionLayers == null) {
      throw const FormatException(
        "its config.json does not say what its context costs",
      );
    }
    return config;
  }

  final Map _json;
  final Map _text;

  int? _number(String key) => (_text[key] as num?)?.toInt();

  int? get _context => _number("max_position_embeddings");
  int? get _heads => _number("num_attention_heads");
  int? get _kvHeads => _number("num_key_value_heads") ?? _heads;

  int? get _headDim =>
      _number("head_dim") ??
      switch ((_number("hidden_size"), _heads)) {
        (final hidden?, final heads?) when heads > 0 => hidden ~/ heads,
        _ => null,
      };

  List? get _layerTypes =>
      _text["layer_types"] is List ? _text["layer_types"] as List : null;

  /// A hybrid's linear-attention layers keep no per-token cache.
  int? get _attentionLayers =>
      _layerTypes?.where((type) => type == "full_attention").length ??
      _number("num_hidden_layers");

  int get _linearLayers =>
      _layerTypes?.where((type) => type == "linear_attention").length ?? 0;

  int get context => _context!;

  String get quantisation {
    final bits = (_json["quantization"] as Map?)?["bits"];
    return bits is int ? "$bits-bit" : "unquantised";
  }

  /// K and V, f16, for every layer that has attention.
  int get kvBytesPerToken => _attentionLayers! * _kvHeads! * _headDim! * 2 * 2;

  /// A linear-attention layer's recurrent state, f32, and its convolution's
  /// last few inputs, f16: the same size whatever the conversation.
  int get _stateBytes {
    final keyHeads = _number("linear_num_key_heads") ?? 0;
    final valueHeads = _number("linear_num_value_heads") ?? 0;
    final keyDim = _number("linear_key_head_dim") ?? 0;
    final valueDim = _number("linear_value_head_dim") ?? 0;
    final kernel = _number("linear_conv_kernel_dim") ?? 1;
    final recurrent = valueHeads * keyDim * valueDim * 4;
    final convolution =
        (kernel - 1) * (2 * keyHeads * keyDim + valueHeads * valueDim) * 2;
    return _linearLayers * (recurrent + convolution);
  }

  ModelShape shape(int weightBytes) => ModelShape(
    weightBytes: weightBytes,
    kvBytesPerToken: kvBytesPerToken,
    trainedContext: context,
    stateBytes: _stateBytes,
    attentionLayers: _attentionLayers!,
    attentionHeads: _heads ?? _kvHeads!,
    headDim: _headDim!,
    hiddenSize: _number("hidden_size") ?? 0,
    intermediateSize: _number("intermediate_size") ?? 0,
  );
}
