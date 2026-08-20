import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_registry.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";

import "../data/builtin/builtin_fakes.dart";
import "../harness.dart";

void main() {
  group("reading one out of settings", () {
    test("keeps everything it was written with", () {
      final provider = LlmProviderConfig.fromJson(const {
        "id": "openrouter",
        "api": "openai",
        "baseUrl": "https://openrouter.ai/api/v1",
        "label": "OpenRouter",
        "apiKey": "sk-or-1",
        "models": ["a", "b"],
      });

      expect(provider!.id, "openrouter");
      expect(provider.api, LlmApi.openai);
      expect(provider.displayName, "OpenRouter");
      expect(provider.models, ["a", "b"]);
    });

    test("defaults to the OpenAI shape, which most of them speak", () {
      final provider =
          LlmProviderConfig.fromJson(const {"id": "x", "baseUrl": "https://x.test/v1"});

      expect(provider!.api, LlmApi.openai);
      expect(provider.models, isEmpty);
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
        models: ["claude-x"],
      );

      final back = LlmProviderConfig.fromJson(jsonDecode(jsonEncode(original.toJson())))!;

      expect(back.id, original.id);
      expect(back.api, original.api);
      expect(back.baseUrl, original.baseUrl);
      expect(back.apiKeyEnv, original.apiKeyEnv);
      expect(back.models, original.models);
    });
  });

  group("finding the key", () {
    const named = LlmProviderConfig(
      id: "anthropic",
      api: LlmApi.anthropic,
      baseUrl: "https://api.anthropic.com/v1",
      apiKeyEnv: "ANTHROPIC_API_KEY",
    );

    test("what was typed in wins", () {
      final provider = named.copyWith(apiKey: "sk-typed");

      expect(provider.resolveKey(const {"ANTHROPIC_API_KEY": "sk-env"}), "sk-typed");
    });

    test("otherwise the environment answers", () {
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
      for (final preset in llmProviderPresets) {
        expect(preset.baseUrl, endsWith("/v1"), reason: preset.id);
        expect(preset.apiKey, isEmpty, reason: "${preset.id} must not ship a key");
      }
    });

    test("Ollama Cloud is the hosted one, and reads the key Ollama's own tools do", () {
      final cloud = llmProviderPresets.firstWhere((p) => p.id == "ollama-cloud");

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
            apiKey: "sk-1",
          ),
        ],
        approveMode: ApproveMode.never,
      ).save(config);

      final loaded = AppSettings.load(config);

      expect(loaded.llmProviders.single.id, "ollama-cloud");
      expect(loaded.llmProviders.single.apiKey, "sk-1");
      expect(loaded.approveMode, ApproveMode.never);
      expect(loaded.defaultModelId, "kimi");
    });

    test("settings written before any of this still load", () async {
      final config = tempConfig("agent_chat_providers_old_");
      await config.documents.write(config.settingsFile, jsonEncode({"defaultModelId": "gpt-x"}));

      final loaded = AppSettings.load(config);

      expect(loaded.defaultModelId, "gpt-x");
      expect(loaded.llmProviders, isEmpty);
      // The default for a fresh file is ask.
      expect(loaded.approveMode, ApproveMode.ask);
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
            LlmEndpoint(provider, build: (config, key) {
              built.add("${config.id}:$key");
              return FakeLlmClient(const []);
            }),
        ],
        lookupEnv: (name) => environment[name],
      );
    }

    setUp(() {
      environment = {};
      providers = const [
        LlmProviderConfig(
          id: "fake",
          api: LlmApi.openai,
          baseUrl: "https://fake.test/v1",
          models: ["m1", "m2"],
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

    test("a key edited in settings reaches the next turn", () {
      final registry = registryOver();
      registry.clientFor("fake");

      providers = [providers.single.copyWith(apiKey: "sk-new")];
      registry.clientFor("fake");

      expect(built, ["fake:null", "fake:sk-new"]);
    });

    test("what a provider lists is taken at its word", () async {
      expect(await registryOver().models(), [
        const ModelOption(providerId: "fake", modelId: "m1", label: "fake · m1"),
        const ModelOption(providerId: "fake", modelId: "m2", label: "fake · m2"),
      ]);
    });

    test("a provider that lists none is asked", () async {
      providers = const [
        LlmProviderConfig(id: "fake", api: LlmApi.openai, baseUrl: "https://fake.test/v1"),
      ];

      expect((await registryOver().models()).single.modelId, "fake-model");
    });

    test("closing it closes what it opened", () {
      final registry = registryOver();
      final client = registry.clientFor("fake")! as FakeLlmClient;

      registry.close();

      expect(client.closed, isTrue);
    });
  });
}
