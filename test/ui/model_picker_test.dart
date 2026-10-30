import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/on_device_provider.dart";
import "package:agent_chat/data/local/local_engine.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/local_model.dart" show appleModelId, appleProviderId;
import "package:agent_chat/domain/model_registry.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/widgets/model_catalog_page.dart" show catalogEntries;
import "package:agent_chat/ui/widgets/model_picker.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";
import "../harness.dart";

/// The rules every settings page inherits, tested once on the widget that owns
/// them rather than four times through the pages.
void main() {
  late TestApp app;
  ModelChoice? reported;

  // The Apple system model is listed by the device before anything is set
  // up; only the title picker offers it.
  test("a title-only model is offered for the title alone", () {
    const listed = [
      ModelOption(providerId: appleProviderId, modelId: appleModelId, label: "Apple · On-device"),
      ModelOption(providerId: "lan", modelId: "qwen", label: "LAN · qwen"),
    ];
    List<String> offered(ModelRole role) => [
          for (final e in catalogEntries(ModelCatalog.empty, const [], listed, role: role))
            e.info.id,
        ];

    expect(offered(ModelRole.agent), ["qwen"]);
    expect(offered(ModelRole.text), ["qwen"]);
    expect(offered(ModelRole.title), unorderedEquals([appleModelId, "qwen"]));
  });

  test("a voice role offers its own kind, and what is on the device", () {
    final catalog = ModelCatalog.parse(jsonEncode({
      testProviderId: {
        "models": {
          "chat": {"tool_call": true},
          "stt": {"modalities": {"input": ["audio"], "output": ["text"]}},
          "tts": {"modalities": {"input": ["text"], "output": ["audio"]}},
        },
      },
    }));
    const listed = [ModelOption(providerId: testProviderId, modelId: "my-finetune")];
    final onDevice = OnDeviceProvider(const NoLocalEngine(),
        () => AppSettings(),
        voices: () => const {"whisper-tiny", "piper-en_US-amy"});
    List<String> offered(ModelRole role) => [
          for (final e in catalogEntries(
              catalog, [onDevice, providerOf(testProvider)], listed,
              role: role))
            "${e.providerId}/${e.info.id}",
        ];

    // An endpoint's own listing is taken for chat, never for speech.
    expect(offered(ModelRole.transcription), ["test/stt", "on-device/whisper-tiny"]);
    expect(offered(ModelRole.speech), ["on-device/piper-en_US-amy", "test/tts"]);
  });

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// The configured provider, with defaults the Default entry names, and its
  /// models in the catalog.
  Future<void> pump(
    WidgetTester tester, {
    ModelChoice choice = (providerId: null, modelId: null),
    ModelChoice? inherited,
    String? Function(LlmProviderConfig)? defaultOf,
    String nullLabel = noneOptionLabel,
    String? helperOffText,
    ModelRole role = ModelRole.agent,
    List<LlmProviderConfig> providers = const [testProvider],
    List<ModelOption>? listed,
  }) async {
    reported = null;
    app.backend.modelList = listed ?? testProviderModels;
    await io(tester, () => app.seedProviders(providers));
    await app.pump(
      tester,
      Scaffold(
        body: ModelPicker(
          choice: choice,
          nullLabel: nullLabel,
          defaultOf: defaultOf ?? (config) => config.defaultModelId,
          inherited: inherited,
          helperOffText: helperOffText,
          role: role,
          onChanged: (c) => reported = c,
        ),
      ),
    );
  }

  /// What the closed field reads.
  String fieldText(WidgetTester tester) => tester
      .widget<Text>(find.descendant(
          of: find.byType(InputDecorator), matching: find.byType(Text)).first)
      .data!;

  List<String> cards(WidgetTester tester) =>
      catalogLabels(tester).where((l) => l.startsWith("Test · ")).toList();

  testWidgets("the quick picks lead, then the models by name", (tester) async {
    useWindow(tester, const Size(800, 1200));
    await pump(tester);

    await openModelCatalog(tester);
    final labels = catalogLabels(tester);
    expect(labels.indexOf(noneOptionLabel), lessThan(labels.indexOf("Test - Default")));
    expect(cards(tester), [
      "Test · claude-haiku-3",
      "Test · claude-sonnet-4",
      "Test · llama-3",
      "Test · qwen-2.5",
    ]);
  });

  testWidgets("a light picker's Default entry names the light default", (tester) async {
    await pump(tester, defaultOf: LlmProviderConfig.lightDefaultOf, nullLabel: "Off");

    await openModelCatalog(tester);
    expect(catalogLabels(tester), contains("nemotron-3-nano:30b"));
  });

  testWidgets("a search narrows the models to the ones every word names", (tester) async {
    await pump(tester);

    await openModelCatalog(tester);
    await tester.enterText(find.byType(TextField), "claude son");
    await tester.pumpAndSettle();
    expect(cards(tester), ["Test · claude-sonnet-4"]);
  });

  /// One model per kind a role tells apart.
  void seedKinds() => ModelCatalog.notifier.value = ModelCatalog.parse(jsonEncode({
        testProviderId: {
          "models": {
            "agentic": {"tool_call": true},
            "chatty": {"tool_call": false},
            "listener": {
              "modalities": {"input": ["audio"], "output": ["text"]},
            },
            "painter": {
              "modalities": {"input": ["text"], "output": ["image"]},
            },
          },
        },
      }));

  /// The endpoint listing every [seedKinds] model, as `/models` would.
  final kindsListed = [
    for (final id in ["agentic", "chatty", "listener", "painter"])
      ModelOption(providerId: testProviderId, modelId: id, label: "Test · $id"),
  ];

  testWidgets("a model that cannot call tools is not offered for chats", (tester) async {
    seedKinds();
    // Listed too: what the catalog says of a model wins over the endpoint
    // naming it.
    await pump(tester, listed: kindsListed);
    await openModelCatalog(tester);
    expect(cards(tester), ["Test · agentic"]);
  });

  testWidgets("a model only the endpoint lists is offered, once", (tester) async {
    seedKinds();
    await pump(tester, listed: [
      ...kindsListed,
      const ModelOption(providerId: testProviderId, modelId: "my-finetune", label: "Test · my-finetune"),
    ]);
    await openModelCatalog(tester);
    expect(cards(tester), ["Test · agentic", "Test · my-finetune"]);
  });

  testWidgets("a background role is offered any model that talks", (tester) async {
    seedKinds();
    await pump(tester, role: ModelRole.text, nullLabel: "Off", listed: const []);
    await openModelCatalog(tester);
    expect(cards(tester), ["Test · agentic", "Test · chatty"]);
  });

  testWidgets("the image picker offers the models that make images", (tester) async {
    ModelCatalog.notifier.value = ModelCatalog.parse(jsonEncode({
      testProviderId: {
        "models": {
          "agentic": {"tool_call": true},
          "painter": {
            "modalities": {"output": ["image"]},
          },
        },
      },
    }));
    await pump(tester, role: ModelRole.image, defaultOf: (config) => providerOf(config).imageModel);
    await openModelCatalog(tester);
    // The listed models are not guessed to make images.
    expect(cards(tester), ["Test · painter"]);
  });

  testWidgets("an image picker over providers that make no images says so", (tester) async {
    await pump(tester, role: ModelRole.image, defaultOf: (config) => providerOf(config).imageModel);
    await openModelCatalog(tester);
    expect(find.text("No image models"), findsOneWidget);
  });

  testWidgets("a card says what the model costs and can do", (tester) async {
    ModelCatalog.notifier.value = ModelCatalog.parse(jsonEncode({
      testProviderId: {
        "models": {
          "gpt-x": {
            "name": "GPT X",
            "tool_call": true,
            "reasoning": true,
            "modalities": {"input": ["text", "image"]},
            "limit": {"context": 400000},
            "cost": {"input": 1.25, "output": 10},
          },
        },
      },
    }));
    await pump(tester, listed: const []);
    await openModelCatalog(tester);

    for (final text in [
      "GPT X",
      "400K context",
      "\$1.25 in · \$10 out /M",
      "Tools",
      "Reasoning",
      "Sees images",
    ]) {
      expect(find.descendant(of: find.byType(Card), matching: find.text(text)),
          findsOneWidget,
          reason: text);
    }
  });

  testWidgets("before the catalog is fetched, it says only the defaults are there",
      (tester) async {
    ModelCatalog.notifier.value = ModelCatalog.empty;
    await pump(tester);
    await openModelCatalog(tester);
    expect(find.text("Only the default models for now"), findsOneWidget);
  });

  testWidgets("picking a model reports the pair", (tester) async {
    await pump(tester);

    await pickModel(tester, "Test · claude-sonnet-4");

    expect(reported, (providerId: testProviderId, modelId: "claude-sonnet-4"));
  });

  testWidgets("picking the Default entry stores the provider with no model", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: "claude-sonnet-4"));

    await pickModel(tester, "Test - Default");

    expect(reported, (providerId: testProviderId, modelId: null));
  });

  testWidgets("picking None clears both halves", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: "claude-sonnet-4"));

    await pickModel(tester, noneOptionLabel);

    expect(reported, (providerId: null, modelId: null));
  });

  testWidgets("a stored Default choice reads as its provider's Default", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: null));

    expect(fieldText(tester), "Test - Default (glm-5.3-flash)");
  });

  // A provider that names no default — a custom one added by hand, say — has
  // no Default entry, so a stored Default choice against it reads as the null
  // entry.
  testWidgets("a Default choice against a provider with no default reads as None",
      (tester) async {
    const bareProvider = LlmProviderConfig(
      id: "bare",
      name: "Bare",
      api: LlmApi.openai,
      baseUrl: "https://bare.example/v1",
    );
    await pump(tester,
        providers: const [bareProvider], choice: (providerId: "bare", modelId: null));

    expect(fieldText(tester), noneOptionLabel);
  });

  // The field names what is stored rather than pretending it is something
  // else: a turn will ask for that id, and the provider is what answers.
  testWidgets("a model the catalog does not know reads as its id", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: "gone-1"));

    expect(fieldText(tester), "gone-1");
  });

  testWidgets("a model added by hand is stored on its provider and offered", (tester) async {
    useWindow(tester, const Size(800, 1400));
    await pump(tester);
    await openModelCatalog(tester);

    await tester.tap(find.text("Add model"));
    await tester.pumpAndSettle();
    // The requirement is said up front, not only once it is switched off.
    expect(find.textContaining("Required for agentic use"), findsOneWidget);
    expect(find.text("Structured output"), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextFormField, "Model id"), "ft:glm:acme");
    await tester.enterText(
        find.widgetWithText(TextFormField, "Context window"), "65536");
    await tester.tap(find.text("Save"));
    await settleIo(tester);

    final provider = app.container.read(appSettingsProvider).llmProviders.single;
    expect(provider.customModels.single.id, "ft:glm:acme");
    expect(provider.customModels.single.context, 65536);
    expect(provider.customModels.single.answersTurns, isTrue);
    // Back on the catalog, searched for, ready to pick.
    expect(cards(tester), ["Test · ft:glm:acme"]);
    expect(find.text("Added by you"), findsOneWidget);
  });

  group("a model added by hand", () {
    const mine = ModelInfo(id: "ft:glm:acme", context: 65536, toolCall: true);

    Future<void> openWithMine(WidgetTester tester) async {
      useWindow(tester, const Size(800, 1400));
      await pump(tester,
          providers: [testProvider.copyWith(customModels: const [mine])]);
      await openModelCatalog(tester);
      await tester.enterText(find.byType(SearchBar), "acme");
      await tester.pumpAndSettle();
    }

    testWidgets("is edited in the form it was added in", (tester) async {
      await openWithMine(tester);

      await tester.tap(find.byTooltip("Model options"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Edit"));
      await tester.pumpAndSettle();
      expect(find.text("Edit model"), findsOneWidget);
      expect(find.text("65536"), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextFormField, "Model id"), "ft:glm:acme-2");
      await tester.tap(find.text("Save"));
      await settleIo(tester);

      // Renamed rather than added beside.
      final provider = app.container.read(appSettingsProvider).llmProviders.single;
      expect(provider.customModels.map((m) => m.id), ["ft:glm:acme-2"]);
      expect(provider.customModels.single.context, 65536);
    });

    testWidgets("is deleted, after asking", (tester) async {
      await openWithMine(tester);

      await tester.tap(find.byTooltip("Model options"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Delete"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Delete").last);
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).llmProviders.single.customModels,
          isEmpty);
    });

    testWidgets("is the only kind with options", (tester) async {
      useWindow(tester, const Size(800, 1400));
      await pump(tester);
      await openModelCatalog(tester);

      expect(find.byTooltip("Model options"), findsNothing);
    });
  });

  testWidgets("reset puts a pick back on the provider default", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: "claude-sonnet-4"));

    await tester.tap(find.byTooltip("Reset to Test - Default (glm-5.3-flash)"));
    await settleIo(tester);

    expect(reported, (providerId: testProviderId, modelId: null));
  });

  testWidgets("a light picker resets to the first provider naming a light default",
      (tester) async {
    const chatOnly = LlmProviderConfig(
        id: "chat", name: "Chat", api: LlmApi.openai, baseUrl: "https://c.example/v1",
        defaultModelId: "big");
    await pump(tester,
        providers: [chatOnly, testProvider],
        defaultOf: LlmProviderConfig.lightDefaultOf);
    await tester.tap(find.byTooltip("Reset to Test - Default (nemotron-3-nano:30b)"));
    expect(reported, (providerId: testProviderId, modelId: null));
  });

  testWidgets("with no provider, reset is to the null entry", (tester) async {
    await pump(tester,
        providers: const [], choice: (providerId: testProviderId, modelId: "gone-1"));

    await tester.tap(find.byTooltip("Reset to $noneOptionLabel"));
    await settleIo(tester);
    expect(reported, (providerId: null, modelId: null));
  });

  testWidgets("the chat-level Default names what it inherits", (tester) async {
    await pump(
      tester,
      nullLabel: defaultOptionLabel,
      inherited: (providerId: testProviderId, modelId: "qwen-2.5"),
    );

    expect(find.text("Using Test · qwen-2.5"), findsOneWidget);
    await openModelCatalog(tester);
    expect(catalogLabels(tester), contains("Default (Test · qwen-2.5)"));
  });

  testWidgets("the optional picker's Off text is its helper", (tester) async {
    await pump(tester, nullLabel: "Off", helperOffText: "Off, nothing happens.");

    expect(find.text("Off, nothing happens."), findsOneWidget);
  });

  testWidgets("the field sits in a resettable row", (tester) async {
    await pump(tester);
    expect(find.byType(ResettableField), findsOneWidget);
  });
}
