import "package:entoli_core/model/memory_plan.dart";
import "package:flutter_test/flutter_test.dart";

/// How a budget is shared out inside MLX. The shape is Qwen3.5 4B's, the one
/// MLX model the catalog offers, as its `config.json` and its weights say;
/// the budget is an iPhone 18 Pro's (seven tenths of the 6 GB it allows).
void main() {
  const qwen = ModelShape(
    weightBytes: 3034300695,
    kvBytesPerToken: 8 * 4 * 256 * 2 * 2,
    trainedContext: 262144,
    stateBytes: 51511296,
    attentionLayers: 8,
    attentionHeads: 16,
    headDim: 256,
    hiddenSize: 2560,
    intermediateSize: 9216,
  );

  test("the KV cache gets what the rest leaves, and decides the context", () {
    final plan = BudgetPlan(qwen, budgetBytes: 4200000000);

    expect(
      plan.kvBytes,
      4200000000 -
          qwen.weightBytes -
          qwen.stateBytes -
          BudgetPlan.scratchBytes -
          BudgetPlan.cacheBytes,
    );
    expect(plan.contextLength, plan.kvBytes ~/ qwen.kvBytesPerToken);
    expect(plan.contextLength, 23762);
    expect(plan.refusal, isNull);
  });

  test("the prefill's step holds its scratch at the full context", () {
    final plan = BudgetPlan(qwen, budgetBytes: 4200000000);

    expect(plan.prefillStep, 168);
    expect(
      plan.prefillStep * qwen.scratchPerToken(plan.contextLength),
      lessThanOrEqualTo(BudgetPlan.scratchBytes),
    );
  });

  test("heads its fused kernel takes leave the step at MLX's default", () {
    const narrow = ModelShape(
      weightBytes: 1 << 30,
      kvBytesPerToken: 1 << 16,
      trainedContext: 32768,
      attentionHeads: 32,
      headDim: 128,
      hiddenSize: 2048,
      intermediateSize: 8192,
    );

    expect(narrow.scoresWrittenOut, isFalse);
    expect(BudgetPlan(narrow, budgetBytes: 4 << 30).prefillStep, 512);
  });

  test("a roomy budget is held to what the model was trained on", () {
    expect(
      BudgetPlan(qwen, budgetBytes: 64 << 30).contextLength,
      qwen.trainedContext,
    );
  });

  test("a budget with no room to talk refuses the model, saying so", () {
    final plan = BudgetPlan(qwen, budgetBytes: 3400000000);

    expect(plan.contextLength, lessThan(BudgetPlan.minimumContext));
    expect(plan.refusal, contains("3.4 GB"));
  });

  test("a budget smaller than the weights is no context at all", () {
    expect(BudgetPlan(qwen, budgetBytes: 1 << 30).contextLength, 0);
  });
}
