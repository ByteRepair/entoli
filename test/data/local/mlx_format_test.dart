import "dart:convert";
import "dart:io";

import "package:agent_chat/data/local/model_format.dart";
import "package:agent_chat/domain/local_model.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

/// What an MLX directory says about itself once its files are on disk. The
/// configs are the shapes the catalog's repositories publish: a hybrid whose
/// numbers sit under `text_config`, and a plain one.
void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp("mlx-format"));
  tearDown(() async => dir.delete(recursive: true));

  void write(Map<String, Object?> config) {
    File(p.join(dir.path, "config.json")).writeAsStringSync(jsonEncode(config));
    File(p.join(dir.path, "model.safetensors")).writeAsBytesSync(List.filled(100, 0));
  }

  test("a hybrid's cache counts its full-attention layers alone", () {
    write({
      "model_type": "qwen3_5",
      "quantization": {"bits": 4, "group_size": 64},
      "text_config": {
        "max_position_embeddings": 262144,
        "num_attention_heads": 8,
        "num_key_value_heads": 2,
        "head_dim": 256,
        "num_hidden_layers": 4,
        "layer_types": ["linear_attention", "full_attention", "linear_attention", "full_attention"],
      },
    });

    final model = const MlxFormat().describe("q", dir.path, mlxCatalog.first);

    expect(model.file, dir.path);
    expect(model.name, mlxCatalog.first.name);
    expect(model.quantisation, "4-bit");
    expect(model.contextLength, 262144);
    expect(model.kvBytesPerToken, 2 * 2 * 256 * 2 * 2);
    expect(model.bytes, greaterThanOrEqualTo(100));
    expect(model.url, mlxCatalog.first.source);
  });

  test("a plain model's head size is worked out from its width", () {
    write({
      "max_position_embeddings": 4096,
      "num_attention_heads": 16,
      "hidden_size": 2048,
      "num_hidden_layers": 10,
    });

    final model = const MlxFormat().describe("plain", dir.path);

    expect(model.name, "plain");
    expect(model.quantisation, "unquantised");
    expect(model.kvBytesPerToken, 10 * 16 * 128 * 2 * 2);
  });

  test("a directory with no usable config is no model", () {
    expect(() => const MlxFormat().describe("x", dir.path), throwsFormatException);
    write({"model_type": "mystery"});
    expect(() => const MlxFormat().describe("x", dir.path), throwsFormatException);
  });
}
