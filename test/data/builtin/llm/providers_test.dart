import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

import "package:agent_chat/data/builtin/llm/gemini_client.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/llm_provider.dart";

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

  group("capabilities", () {
    test("an OpenAI-shaped provider makes images and has audio endpoints", () {
      const openai = OpenAiProvider();
      final client = openai.client(null);
      expect(openai.answersAudio, isTrue);
      expect(openai.imageGenerator(client, "gpt-image-1"), isNotNull);
      expect(openai.transcriber(client, "whisper-1"), isNotNull);
      expect(openai.synthesizer(client, "tts-1"), isNotNull);
    });

    test("Anthropic offers chat alone", () {
      const anthropic = AnthropicProvider();
      final client = anthropic.client(null);
      expect(anthropic.answersAudio, isFalse);
      expect(anthropic.imageGenerator(client, "any"), isNull);
      expect(anthropic.transcriber(client, "any"), isNull);
      expect(anthropic.synthesizer(client, "any"), isNull);
    });

    test("a local server asks for no key", () {
      expect(const OllamaProvider().needsKey, isFalse);
      expect(const OpenAiProvider().needsKey, isTrue);
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
}
