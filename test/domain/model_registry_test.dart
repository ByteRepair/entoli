import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/apple_fm.dart" show mlxModels;
import "package:agent_chat/domain/local_model.dart";
import "package:agent_chat/domain/model_registry.dart";

/// The heuristic compaction reads: only what is known answers, and the rest
/// is the caller's global guess.
void main() {
  test("the system model answers its constant", () {
    expect(contextWindowOf(appleProviderId, appleModelId), 8192);
  });

  test("a null model on the Apple provider is the provider default", () {
    expect(contextWindowOf(appleProviderId, null), 8192);
  });

  test("an MLX row is not the system model and answers nothing", () {
    expect(contextWindowOf(appleProviderId, mlxModels.first), null);
  });

  test("every other provider answers nothing", () {
    expect(contextWindowOf("openai", "gpt-5"), null);
    expect(contextWindowOf(localProviderId, "qwen3.5-4b-q4_0"), null);
    expect(contextWindowOf(null, null), null);
  });
}
