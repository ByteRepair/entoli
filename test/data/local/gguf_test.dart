import "dart:io";

import "package:agent_chat/data/local/gguf.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "gguf_bytes.dart";

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp("gguf"));
  tearDown(() => dir.delete(recursive: true));

  GgufFacts read(List<int> bytes) {
    final file = File(p.join(dir.path, "model.gguf"))..writeAsBytesSync(bytes);
    return readGgufFacts(file.path);
  }

  test("a model's cost per token is K and V for every layer, at f16", () {
    final facts = read(tinyModel());

    expect(facts.name, "Tiny 1B");
    expect(facts.quantisation, "Q4_0");
    expect(facts.contextLength, 32768);
    expect(facts.kvBytesPerToken, 4 * 2 * (64 + 64) * 2);
  });

  test("a layer with no KV heads holds no cache", () {
    // LFM3's shape: convolution layers between the attention ones.
    final facts = read(ggufBytes({
      "general.architecture": "hybrid",
      "general.file_type": 2,
      "hybrid.block_count": 4,
      "hybrid.context_length": 262144,
      "hybrid.attention.head_count": 16,
      "hybrid.attention.head_count_kv": [0, 4, 0, 4],
      "hybrid.attention.key_length": 128,
    }));

    expect(facts.name, isNull);
    expect(facts.kvBytesPerToken, 8 * (128 + 128) * 2);
  });

  test("a vocabulary is skipped on the way to what comes after it", () {
    final facts = read(ggufBytes({
      "general.architecture": "tiny",
      "tokenizer.ggml.tokens": [for (var i = 0; i < 5000; i++) "token$i"],
      "tiny.block_count": 2,
      "tiny.context_length": 4096,
      "tiny.attention.head_count": 4,
      "tiny.attention.head_count_kv": 4,
      "tiny.embedding_length": 256,
    }));

    // No key length: the embedding over the heads.
    expect(facts.kvBytesPerToken, 2 * 4 * (64 + 64) * 2);
    expect(facts.quantisation, "unknown");
  });

  test("a file that is not a model says so", () {
    expect(() => read(List.filled(64, 7)), throwsFormatException);
    expect(() => read(ggufBytes({"general.architecture": "tiny"})), throwsFormatException);
  });
}
