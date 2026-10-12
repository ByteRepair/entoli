import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/local_model.dart";

/// How much context a model gets when nothing overrides it. It used to be one
/// number for the whole catalog, which made the smallest model as cramped as
/// the largest while costing a third of the memory — so what is worth pinning
/// is that the answer follows from the model rather than from a constant.
void main() {
  LocalModel modelWith(int kvBytesPerToken) => LocalModel(
        id: "test",
        name: "Test",
        parameters: "1B",
        url: "https://example.invalid/model.gguf",
        bytes: 1,
        sha256: "",
        contextLength: 262144,
        kvBytesPerToken: kvBytesPerToken,
        licence: "Apache-2.0",
      );

  test("the budget is what decides it, divided by what a token costs", () {
    // 48 KiB a token is the two smaller Qwen3.5s: 24 layers, 2 KV heads, 256
    // wide, K and V, at f16.
    expect(modelWith(48 * 1024).defaultContext, 16384);
    // 128 KiB is the two larger ones — 32 layers and 4 KV heads — so the same
    // gigabyte buys a quarter of the context.
    expect(modelWith(128 * 1024).defaultContext, 8192);
  });

  test("no entry in the catalog is given more than the budget", () {
    for (final model in localModelCatalog) {
      expect(model.defaultContext * model.kvBytesPerToken,
          lessThanOrEqualTo(kvBudgetBytes),
          reason: model.id);
      // Nor so little that the agent's own prompt would not fit: the system
      // prompt and the tool schemas are about 2,700 tokens before the user has
      // typed anything, which is what made 4,096 unusable.
      expect(model.defaultContext, greaterThan(4096), reason: model.id);
    }
  });

  test("a model is never run past what it was trained for", () {
    for (final model in localModelCatalog) {
      expect(model.defaultContext, lessThanOrEqualTo(model.contextLength),
          reason: model.id);
    }
  });
}
