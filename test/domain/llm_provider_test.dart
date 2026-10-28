import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_registry.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/permission.dart";

import "../data/builtin/builtin_fakes.dart";
import "../harness.dart";

void main() {
  group("reading one out of settings", () {
    test("keeps everything it was written with, and ignores an old key", () {
      final provider = LlmProviderConfig.fromJson(const {
        "id": "openrouter",
        "api": "openai",
        "baseUrl": "https://openrouter.ai/api/v1",
        "label": "OpenRouter",
        "apiKey": "sk-or-1",
        "modelsEndpoint": "https://openrouter.ai/api/v1/models",
      });

      expect(provider!.id, "openrouter");
      expect(provider.api, LlmApi.openai);
      expect(provider.displayName, "OpenRouter");
      expect(provider.modelsEndpoint, "https://openrouter.ai/api/v1/models");
      // The key is not the config's any more; nothing here carries one.
      expect(
          provider.resolveKeyWith((name) => name == "ANTHROPIC_API_KEY" ? "x" : null),
          isNull);
    });

    test("defaults to the OpenAI shape, which most of them speak", () {
      final provider =
          LlmProviderConfig.fromJson(const {"id": "x", "baseUrl": "https://x.test/v1"});

      expect(provider!.api, LlmApi.openai);
      expect(provider.modelsEndpoint, isNull);
      expect(provider.displayName, "x");
    });

    test("an entry missing its name or its URL is dropped", () {
      expect(LlmProviderConfig.fromJson(const {"baseUrl": "https://x.test"}), isNull);
      expect(LlmProviderConfig.fromJson(const {"id": "x"}), isNull);
      expect(LlmProviderConfig.fromJson("not a map"), isNull);
    });

    test("a round trip through JSON changes nothing", () {
      const original = LlmProviderConfig(
        id: "anthropic",
        api: LlmApi.anthropic,
        baseUrl: "https://api.anthropic.com/v1",
        apiKeyEnv: "ANTHROPIC_API_KEY",
        modelsEndpoint: "https://api.anthropic.com/v1/models",
      );

      final back = LlmProviderConfig.fromJson(jsonDecode(jsonEncode(original.toJson())))!;

      expect(back.id, original.id);
      expect(back.api, original.api);
      expect(back.baseUrl, original.baseUrl);
      expect(back.apiKeyEnv, original.apiKeyEnv);
      expect(back.modelsEndpoint, original.modelsEndpoint);
    });
  });

  group("finding the key", () {
    const named = LlmProviderConfig(
      id: "anthropic",
      api: LlmApi.anthropic,
      baseUrl: "https://api.anthropic.com/v1",
      apiKeyEnv: "ANTHROPIC_API_KEY",
    );

    test("the environment answers", () {
      expect(named.resolveKey(const {"ANTHROPIC_API_KEY": "sk-env"}), "sk-env");
    });

    test("an empty variable is no key at all", () {
      expect(named.resolveKey(const {"ANTHROPIC_API_KEY": ""}), isNull);
      expect(named.resolveKey(const {}), isNull);
    });

    test("a provider that needs no key says so", () {
      const local = LlmProviderConfig(
          id: "ollama", api: LlmApi.openai, baseUrl: "http://localhost:11434/v1");

      expect(local.resolveKey(const {}), isNull);
    });
  });

  group("the presets", () {
    test("cover the endpoints worth naming, each with a versioned root", () {
      expect(llmProviderPresets.map((p) => p.id),
          containsAll(["anthropic", "openai", "openrouter", "ollama-cloud", "ollama"]));
      for (final preset in llmProviderPresets.map((p) => p.config)) {
        expect(preset.baseUrl, contains(RegExp(r"/v\d")), reason: preset.id);
        // A preset names a variable, never key material: nothing shipped
        // carries a credential.
        expect(preset.toJson().containsKey("apiKey"), isFalse, reason: preset.id);
      }
    });

    test("Ollama Cloud is the hosted one, and reads the key Ollama's own tools do", () {
      const cloud = OllamaCloudProvider.preset;

      expect(cloud.baseUrl, "https://ollama.com/v1");
      expect(cloud.api, LlmApi.openai);
      expect(cloud.apiKeyEnv, "OLLAMA_API_KEY");
    });
  });

  group("through settings.json", () {
    test("providers survive a save and a load", () async {
      final config = tempConfig("agent_chat_providers_");
      await AppSettings(
        defaultProviderId: "ollama-cloud",
        defaultModelId: "kimi",
        llmProviders: const [
          LlmProviderConfig(
            id: "ollama-cloud",
            api: LlmApi.openai,
            baseUrl: "https://ollama.com/v1",
            apiKeyEnv: "OLLAMA_API_KEY",
          ),
        ],
        approveMode: ApproveMode.never,
      ).save(config);

      final loaded = AppSettings.load(config);

      expect(loaded.llmProviders.single.id, "ollama-cloud");
      expect(loaded.llmProviders.single.apiKeyEnv, "OLLAMA_API_KEY");
      expect(loaded.approveMode, ApproveMode.never);
      expect(loaded.defaultModelId, "kimi");
    });

    test("settings written before any of this still load", () async {
      final config = tempConfig("agent_chat_providers_old_");
      await config.documents.write(config.settingsFile, jsonEncode({"defaultModelId": "gpt-x"}));

      final loaded = AppSettings.load(config);

      expect(loaded.defaultModelId, "gpt-x");
      expect(loaded.llmProviders, isEmpty);
      // The default for a fresh file is auto, which with no classifier
      // configured amounts to ask.
      expect(loaded.approveMode, ApproveMode.auto);
    });

    test("an environment under its old name is still found, and is rewritten", () async {
      final config = tempConfig("agent_chat_providers_env_");
      await config.documents.write(config.settingsFile, jsonEncode({
        "opencodeEnv": {"ANTHROPIC_API_KEY": "sk-old"},
      }));

      final loaded = AppSettings.load(config);
      expect(loaded.environment, {"ANTHROPIC_API_KEY": "sk-old"});

      await loaded.save(config);
      expect(File(config.settingsFile).readAsStringSync(), isNot(contains("opencodeEnv")));
      expect(AppSettings.load(config).environment, {"ANTHROPIC_API_KEY": "sk-old"});
    });

    test("a provider entry that is broken does not take the rest with it", () async {
      final config = tempConfig("agent_chat_providers_bad_");
      await config.documents.write(config.settingsFile, jsonEncode({
        "llmProviders": [
          {"id": "good", "baseUrl": "https://good.test/v1"},
          {"baseUrl": "https://nameless.test/v1"},
        ],
      }));

      expect(AppSettings.load(config).llmProviders.map((p) => p.id), ["good"]);
    });
  });

  group("the registry", () {
    late List<LlmProviderConfig> providers;
    late Map<String, String> environment;
    late List<String> built;

    LlmRegistry registryOver() {
      built = [];
      return LlmRegistry(
        endpoints: () => [
          for (final provider in providers)
            FakeProvider(provider, (config, key) {
              built.add("${config.id}:$key");
              return FakeLlmClient(const []);
            }),
        ],
        lookupEnv: (name) => environment[name],
        lookupKey: (_) => null,
      );
    }

    setUp(() {
      environment = {};
      providers = const [
        LlmProviderConfig(
          id: "fake",
          api: LlmApi.openai,
          baseUrl: "https://fake.test/v1",
        ),
      ];
    });

    test("a provider nothing is configured for has no client", () {
      expect(registryOver().clientFor("ghost"), isNull);
    });

    test("the same provider is built once and reused", () {
      final registry = registryOver();

      expect(registry.clientFor("fake"), same(registry.clientFor("fake")));
      expect(built, hasLength(1));
    });

    test("a URL edited in settings reaches the next turn", () {
      final registry = registryOver();
      registry.clientFor("fake");

      providers = [
        providers.single.copyWith(baseUrl: "https://moved.test/v1"),
      ];
      registry.clientFor("fake");

      expect(built, hasLength(2));
    });

    test("the model list is what each provider lists, with no client built", () async {
      expect((await registryOver().models()).single.modelId, "fake-model");
      expect(built, isEmpty);
    });

    test("closing it closes what it opened", () {
      final registry = registryOver();
      final client = registry.clientFor("fake")! as FakeLlmClient;

      registry.close();

      expect(client.closed, isTrue);
    });
  });

  group("the registry over stored keys", () {
    LlmRegistry registryOver(Map<String, String> stored) => LlmRegistry(
          endpoints: () => [
            for (final provider in [
              const LlmProviderConfig(
                id: "fake",
                api: LlmApi.openai,
                baseUrl: "https://fake.test/v1",
                apiKeyEnv: "FAKE_API_KEY",
              ),
            ])
              FakeProvider(provider, (config, key) => FakeLlmClient(const [])),
          ],
          lookupEnv: (name) => name == "FAKE_API_KEY" ? "sk-env" : null,
          lookupKey: (id) => stored[id],
        );

    test("a stored key wins over the named environment variable", () {
      expect(
        registryOver({"fake": "sk-stored"}).resolveKeyFor(const LlmProviderConfig(
          id: "fake",
          api: LlmApi.openai,
          baseUrl: "https://fake.test/v1",
        )),
        "sk-stored",
      );
    });

    test("with nothing stored the named environment variable is still asked", () {
      expect(
        registryOver(const {}).resolveKeyFor(const LlmProviderConfig(
          id: "fake",
          api: LlmApi.openai,
          baseUrl: "https://fake.test/v1",
          apiKeyEnv: "FAKE_API_KEY",
        )),
        "sk-env",
      );
    });

    test("an edited stored key rebuilds the client", () {
      final stored = <String, String>{"fake": "sk-1"};
      final registry = LlmRegistry(
        endpoints: () => [
          providerOf(const LlmProviderConfig(
              id: "fake", api: LlmApi.openai, baseUrl: "https://fake.test/v1")),
        ],
        lookupEnv: (_) => null,
        lookupKey: (id) => stored[id],
      );
      final first = registry.clientFor("fake");

      stored["fake"] = "sk-2";
      final second = registry.clientFor("fake");

      expect(second, isNot(same(first)));
    });
  });
}
