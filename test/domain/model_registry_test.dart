import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/apple_fm.dart" show mlxModels;
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/local_model.dart";
import "package:agent_chat/domain/model_registry.dart";

const _openai = LlmProviderConfig(
    id: "openai", api: LlmApi.openai, baseUrl: "https://api.openai.com/v1");

/// A slice of models.dev as it is served: one provider keyed by our preset's
/// id, one only reachable by its base URL.
final _source = jsonEncode({
  "openai": {
    "models": {
      "gpt-x": {
        "name": "GPT X",
        "tool_call": true,
        "reasoning": true,
        "modalities": {"input": ["text", "image"], "output": ["text"]},
        "limit": {"context": 400000, "output": 128000},
        "cost": {"input": 1.25, "output": 10},
        "release_date": "dropped by the trim",
      },
      "gpt-image-x": {
        "modalities": {"input": ["text"], "output": ["image"]},
        "limit": {"context": 0},
      },
      "whisper-x": {
        "modalities": {"input": ["audio"], "output": ["text"]},
      },
    },
  },
  "somehost": {
    "api": "https://some.host/v1",
    "models": {
      "text-only": {"tool_call": true},
    },
  },
});

void main() {
  tearDown(() => ModelCatalog.notifier.value = ModelCatalog.empty);

  group("on-device", () {
    test("the Apple system model answers its constant", () {
      final apple = LlmProviderConfig(id: appleProviderId, api: LlmApi.openai, baseUrl: "");
      expect(modelInfoOf(apple, appleModelId)?.context, 8192);
      expect(modelInfoOf(apple, null)?.context, 8192);
      expect(modelInfoOf(apple, mlxModels.first), isNull);
    });

    test("nothing is known where there is no provider or no model", () {
      expect(modelInfoOf(null, "gpt-x"), isNull);
      expect(modelInfoOf(_openai, null), isNull);
    });
  });

  group("the catalog", () {
    setUp(() => ModelCatalog.notifier.value = ModelCatalog.parse(_source));

    test("a model is read from the provider of the same id", () {
      final info = modelInfoOf(_openai, "gpt-x")!;
      expect(info.displayName, "GPT X");
      expect(info.readsImages, isTrue);
      expect(info.makesImages, isFalse);
      expect(info.answersTurns, isTrue);
      expect(info.reasoning, isTrue);
      expect((info.context, info.output), (400000, 128000));
      expect((info.inputCost, info.outputCost), (1.25, 10.0));
    });

    test("an image model's zero window is no answer", () {
      final info = modelInfoOf(_openai, "gpt-image-x")!;
      expect(info.makesImages, isTrue);
      expect(info.context, isNull);
    });

    test("a model talks when it takes text and gives text", () {
      expect(modelInfoOf(_openai, "gpt-x")!.talks, isTrue);
      expect(modelInfoOf(_openai, "gpt-image-x")!.talks, isFalse);
      expect(modelInfoOf(_openai, "whisper-x")!.talks, isFalse);
      // Naming no modalities is the ordinary case.
      expect(ModelInfo.fromJson("bare", const {}).talks, isTrue);
    });

    test("a turn wants tools and talk, nothing else", () {
      expect(const ModelInfo(id: "a", toolCall: true).answersTurns, isTrue);
      expect(const ModelInfo(id: "b").answersTurns, isFalse);
      expect(const ModelInfo(id: "c", toolCall: true, talks: false).answersTurns, isFalse);
    });

    test("a provider of our own naming is found by its base URL", () {
      const mine = LlmProviderConfig(
          id: "my-host", api: LlmApi.openai, baseUrl: "https://some.host/v1/");
      expect(modelInfoOf(mine, "text-only")?.readsImages, isFalse);
      expect(modelInfoOf(mine, "gpt-x"), isNull);
    });

    test("an unknown model is no answer rather than a guess", () {
      expect(modelInfoOf(_openai, "gpt-y"), isNull);
    });

    test("a model added by hand comes before the catalog's", () {
      final custom = _openai.copyWith(customModels: [
        const ModelInfo(id: "gpt-x", name: "Mine"),
        const ModelInfo(id: "ft:gpt-x:acme", toolCall: true),
      ]);
      expect(modelInfoOf(custom, "gpt-x")?.name, "Mine");
      expect(ModelCatalog.current.modelsOf(custom).map((m) => m.id),
          ["gpt-x", "ft:gpt-x:acme", "gpt-image-x", "whisper-x"]);
    });

    test("the trimmed copy reads back the same and carries when it was fetched", () {
      final at = DateTime.utc(2026, 10, 19);
      final text = ModelCatalog.current.fetchedAt(at).toJsonText();
      expect(text, isNot(contains("release_date")));
      ModelCatalog.notifier.value = ModelCatalog.parse(text);
      expect(ModelCatalog.current.fetched, at);
      expect(modelInfoOf(_openai, "gpt-x")?.toJson(),
          ModelCatalog.parse(_source).lookup(_openai, "gpt-x")?.toJson());
      expect(modelInfoOf(
              const LlmProviderConfig(
                  id: "x", api: LlmApi.openai, baseUrl: "https://some.host/v1"),
              "text-only"),
          isNotNull);
    });

    test("the built-in defaults have no fetch time", () {
      expect(ModelCatalog.current.fetched, isNull);
    });
  });

  test("a provider's own models survive its settings round trip", () {
    final config = _openai.copyWith(customModels: [
      const ModelInfo(id: "ft:1", context: 1000, toolCall: true, readsImages: true),
    ]);
    final back = LlmProviderConfig.fromJson(jsonDecode(jsonEncode(config.toJson())))!;
    final model = back.customModels.single;
    expect((model.id, model.context, model.toolCall, model.readsImages),
        ("ft:1", 1000, true, true));
  });
}
