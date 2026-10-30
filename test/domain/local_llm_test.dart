import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/local_model.dart";

/// How much context a model gets when nothing overrides it. It used to be one
/// number for the whole catalog, which made the smallest model as cramped as
/// the largest while costing a third of the memory — so what is worth pinning
/// is that the answer follows from the model rather than from a constant.
void main() {
  DownloadedModel modelWith(
    int kvBytesPerToken, {
    int contextLength = 262144,
  }) => DownloadedModel(
    id: "test",
    name: "Test",
    file: "/models/test/model.gguf",
    bytes: 1,
    quantisation: "Q4_0",
    contextLength: contextLength,
    kvBytesPerToken: kvBytesPerToken,
  );

  test("the budget is what decides it, divided by what a token costs", () {
    // 22 KiB a token is LFM3 1.7B: eleven attention layers of four KV heads,
    // 128 wide, K and V, at f16.
    expect(modelWith(22528).defaultContext, 32768);
    // 128 KiB is a Qwen3.5 4B — 32 layers and 4 KV heads — so the same
    // gigabyte buys a quarter of the context.
    expect(modelWith(128 * 1024).defaultContext, 8192);
  });

  test("a model is never run past what it was trained for", () {
    expect(modelWith(1024, contextLength: 4096).defaultContext, 4096);
  });

  test("a record reads back what it was written as", () {
    final model = modelWith(22528);
    final back = DownloadedModel.fromJson(model.toJson(), file: model.file)!;

    expect(back.toJson(), model.toJson());
    expect(DownloadedModel.fromJson({"id": "x"}, file: ""), isNull);
  });

  test("a link names its model by its file, past one already taken", () {
    const url = "https://huggingface.co/a/b/resolve/main/Some-Model-Q4_0.gguf";
    expect(localModelIdFor(url, const {}), "some-model-q4_0");
    expect(
      localModelIdFor(url, const {"some-model-q4_0"}),
      "some-model-q4_0-2",
    );
  });
}
