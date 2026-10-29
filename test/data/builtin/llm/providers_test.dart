import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

import "package:agent_chat/data/builtin/llm/gemini_client.dart";
import "package:agent_chat/data/builtin/llm/hosted_models.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/model_capability.dart";
import "package:agent_chat/domain/model_registry.dart";
import "package:agent_chat/domain/voice.dart";

void main() {
  group("providerOf", () {
    test("reads a renamed entry by its host", () {
      final provider = providerOf(GoogleProvider.preset.copyWith(id: "gemini"));
      expect(provider, isA<GoogleProvider>());
      expect(provider.client(null), isA<GeminiClient>());
    });

    test("reads a local server by its preset id", () {
      expect(providerOf(OllamaProvider.preset), isA<OllamaProvider>());
    });

    test("reads an endpoint typed in by hand by its wire format", () {
      const custom = LlmProviderConfig(
          id: "vllm", api: LlmApi.openai, baseUrl: "http://gpu.local:8000/v1");
      expect(providerOf(custom).runtimeType, OpenAiCompatibleProvider);
      expect(providerOf(custom.copyWith(api: LlmApi.anthropic)).runtimeType,
          AnthropicCompatibleProvider);
    });

    test("every preset is read back as itself", () {
      for (final preset in llmProviderPresets) {
        expect(providerOf(preset.config).runtimeType, preset.runtimeType,
            reason: preset.id);
      }
    });
  });

  group("keys", () {
    test("a local server asks for no key", () {
      expect(const OllamaProvider().needsKey, isFalse);
      expect(const OpenAiProvider().needsKey, isTrue);
    });
  });

  group("serve", () {
    final host = ModelHost.resolving();
    List<Type> kinds(List<Model> models) => [
          for (final m in models)
            switch (m) {
              ChatModel() => ChatModel,
              ImageModel() => ImageModel,
              TranscriptionModel() => TranscriptionModel,
              SynthesisModel() => SynthesisModel,
              _ => Model,
            },
        ];

    test("a described model is what its description says", () {
      final tts = ModelInfo.fromJson("tts-1", {
        "modalities": {"input": ["text"], "output": ["audio"]},
      });
      expect(kinds(const OpenAiProvider().serve("tts-1", tts, host)), [SynthesisModel]);
      final chat = ModelInfo.fromJson("gpt-5", {
        "modalities": {"input": ["text", "image"], "output": ["text"]},
      });
      expect(kinds(const OpenAiProvider().serve("gpt-5", chat, host)), [ChatModel]);
    });

    test("one it does not describe is anything its API answers", () {
      expect(kinds(const OpenAiProvider().serve("whisper-1", null, host)),
          [ChatModel, ImageModel, TranscriptionModel, SynthesisModel]);
      expect(kinds(const AnthropicProvider().serve("any", null, host)), [ChatModel]);
    });

    test("nothing hears through a provider where nothing cuts utterances", () {
      final models = const OpenAiProvider()
          .serve("whisper-1", null, ModelHost.resolving(cutsUtterances: false));
      expect(models.whereType<TranscriptionModel>(), isEmpty);
    });

    test("resolves a pick to the kind asked for, with the pick's ref", () {
      final model = OpenAiProvider(OpenAiProvider.preset.copyWith(id: "mine"))
          .resolve<SynthesisModel>("tts-1", host);
      expect(model?.ref, (providerId: "mine", modelId: "tts-1"));
      expect(model?.speaking(voice: "alloy"), isA<SpeakThrough>());
    });
  });

  group("checkKey", () {
    late List<http.Request> requests;

    http.Client answering(int status) => MockClient((request) async {
          requests.add(request);
          return http.Response("{}", status);
        });

    setUp(() => requests = []);

    test("a key the provider accepts is a yes, and is the one sent", () async {
      expect(await const OpenAiProvider().checkKey("sk-1", httpClient: answering(200)),
          isTrue);
      expect(requests.single.url.toString(), "https://api.openai.com/v1/models");
      expect(requests.single.headers["authorization"], "Bearer sk-1");
    });

    test("a refused key is a no", () async {
      expect(await const OpenAiProvider().checkKey("sk-1", httpClient: answering(401)),
          isFalse);
    });

    test("a spent balance is a key that was accepted", () async {
      expect(await const OpenAiProvider().checkKey("sk-1", httpClient: answering(402)),
          isTrue);
    });

    test("a server error is not a no", () {
      expect(const OpenAiProvider().checkKey("sk-1", httpClient: answering(500)),
          throwsA(isA<LlmException>()));
    });

    test("Anthropic is asked with its own header", () async {
      await const AnthropicProvider().checkKey("sk-ant", httpClient: answering(200));
      expect(requests.single.headers["x-api-key"], "sk-ant");
      expect(requests.single.headers.containsKey("anthropic-version"), isTrue);
    });

    test("Google's 400 is a refused key", () async {
      expect(await const GoogleProvider().checkKey("k", httpClient: answering(400)),
          isFalse);
    });

    test("OpenRouter asks about the key, its model list being public", () async {
      await const OpenRouterProvider().checkKey("k", httpClient: answering(200));
      expect(requests.single.url.path, "/api/v1/key");
    });

    test("Z.ai asks for one token from its light model", () async {
      await const ZaiProvider().checkKey("k", httpClient: answering(200));
      expect(requests.single.url.path, endsWith("/chat/completions"));
      expect(requests.single.body, contains(ZaiProvider.preset.defaultLightModelId!));
    });

    test("a local server asks nothing", () async {
      expect(await const OllamaProvider().checkKey("", httpClient: answering(500)),
          isTrue);
      expect(requests, isEmpty);
    });
  });

  group("listModels", () {
    late List<http.Request> requests;

    http.Client listing(List<String> ids) => MockClient((request) async {
          requests.add(request);
          return http.Response(
              jsonEncode({
                "data": [for (final id in ids) {"id": id}],
              }),
              200);
        });

    setUp(() => requests = []);

    test("a provider with no models endpoint lists models.dev's, asking nothing",
        () async {
      ModelCatalog.notifier.value = ModelCatalog.parse(jsonEncode({
        "openai": {
          "models": {"gpt-a": {"tool_call": true}},
        },
      }));
      addTearDown(() => ModelCatalog.notifier.value = ModelCatalog.empty);

      expect(await const OpenAiProvider().listModels("k", httpClient: listing(["x"])),
          ["gpt-a"]);
      expect(requests, isEmpty);
    });

    test("a models endpoint is asked with the provider's own header", () async {
      final provider = AnthropicProvider(AnthropicProvider.preset
          .copyWith(modelsEndpoint: "https://gateway.test/v1/models"));

      expect(await provider.listModels("sk-ant", httpClient: listing(["claude-a"])),
          ["claude-a"]);
      expect(requests.single.url.toString(), "https://gateway.test/v1/models");
      expect(requests.single.headers["x-api-key"], "sk-ant");
    });

    test("a local server lists its own unless another is named", () async {
      await const OllamaProvider().listModels(null, httpClient: listing(["qwen3"]));
      expect(requests.single.url.toString(), "http://localhost:11434/v1/models");
    });

    test("an endpoint that will not say contributes nothing", () async {
      final provider = OpenAiProvider(OpenAiProvider.preset
          .copyWith(modelsEndpoint: "https://example.test/v1/models"));

      expect(
          await provider.listModels("k",
              httpClient: MockClient((_) async => http.Response("nope", 404))),
          isEmpty);
    });
  });
}
