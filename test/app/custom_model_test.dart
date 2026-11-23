import "package:agent_chat/app/custom_model.dart";
import "package:agent_chat/app/model_role.dart";
import "package:entoli_core/model/model_info.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  CustomModelDraft draft({
    ModelRole role = ModelRole.agent,
    ModelInfo? model,
  }) => CustomModelDraft(
    role: role,
    providers: const [("p1", "Box"), ("p2", "Cloud")],
    providerId: model == null ? null : "p2",
    model: model,
  );

  test("a chat model keeps what it can do, a speech model none of it", () {
    final chat = draft()
      ..id = "tuned-1"
      ..caps = {ModelCap.toolCall, ModelCap.readsImages};
    final saved = chat.build();
    expect(saved.providerId, "p1");
    expect(saved.info.toolCall, isTrue);
    expect(saved.info.readsImages, isTrue);
    expect(saved.info.reasoning, isFalse);
    final speech = draft()
      ..id = "tts"
      ..kind = ModelRole.speech
      ..caps = {ModelCap.toolCall};
    expect(speech.build().info.speaks, isTrue);
    expect(speech.build().info.toolCall, isFalse);
  });

  test("needs an id and numbers where numbers go", () {
    final d = draft();
    expect(d.ready, isFalse);
    d.id = "tuned-1";
    expect(d.ready, isTrue);
    d.context = "lots";
    expect(d.ready, isFalse);
  });

  test("an edit replaces the model it started from", () {
    final d = draft(model: const ModelInfo(id: "old", reasoning: true));
    expect(d.caps, contains(ModelCap.reasoning));
    expect(d.edited, isFalse);
    d.id = "new";
    expect(d.edited, isTrue);
    final saved = d.build();
    expect(saved.replacing, ("p2", "old"));
    expect(saved.info.id, "new");
  });
}
