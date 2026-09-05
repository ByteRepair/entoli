import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/widgets/model_picker.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";
import "../harness.dart";

/// The rules every settings page inherits, tested once on the widget that owns
/// them rather than four times through the pages.
void main() {
  late TestApp app;
  ModelChoice? reported;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// The configured provider, with defaults the injected Default entry names,
  /// and its models labelled the way the registry labels them —
  /// "<provider> · <model>".
  Future<void> pump(
    WidgetTester tester, {
    ModelChoice choice = (providerId: null, modelId: null),
    ModelChoice? inherited,
    String? Function(LlmProviderConfig)? defaultOf,
    String nullLabel = noneOptionLabel,
    String? helperOffText,
    List<ModelOption>? models,
  }) async {
    final modelList = models ?? testProviderModels;
    reported = null;
    app.backend.modelList = modelList;
    await io(tester, () => app.seedProviders([testProvider]));
    await app.pump(
      tester,
      Scaffold(
        body: ModelPicker(
          choice: choice,
          nullLabel: nullLabel,
          defaultOf: defaultOf ?? (config) => config.defaultModelId,
          inherited: inherited,
          helperOffText: helperOffText,
          onChanged: (c) => reported = c,
        ),
      ),
    );
  }

  Finder entry(String label) => find.widgetWithText(DropdownMenuItem<ModelChoice>, label).last;

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(DropdownButtonFormField<ModelChoice>));
    await tester.pumpAndSettle();
  }

  testWidgets("None leads the list, then the Default entry, then the models", (tester) async {
    await pump(tester);

    await open(tester);
    expect(
      popupLabels(tester),
      [
        noneOptionLabel,
        "Test - Default (glm-5.3-flash)",
        "Test · claude-haiku-3",
        "Test · claude-sonnet-4",
        "Test · llama-3",
        "Test · qwen-2.5",
      ],
    );
  });

  testWidgets("the Default entry names the light default where the picker is a light one",
      (tester) async {
    await pump(
      tester,
      defaultOf: (config) => config.defaultLightModelId,
      nullLabel: "Off",
      helperOffText: "Off, nothing happens.",
    );

    await open(tester);
    expect(popupLabels(tester), contains("Test - Default (nemotron-3-nano:30b)"));
  });

  testWidgets("picking a model reports the pair", (tester) async {
    await pump(tester);

    await open(tester);
    await tester.tap(find.text("Test · claude-sonnet-4").last);
    await settleIo(tester);

    expect(reported, (providerId: testProviderId, modelId: "claude-sonnet-4"));
  });

  testWidgets("picking the Default entry stores the provider with no model", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: "claude-sonnet-4"));

    await open(tester);
    await tester.tap(entry("Test - Default (glm-5.3-flash)"));
    await settleIo(tester);

    expect(reported, (providerId: testProviderId, modelId: null));
  });

  testWidgets("picking None clears both halves", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: "claude-sonnet-4"));

    await open(tester);
    await tester.tap(find.text(noneOptionLabel).last);
    await settleIo(tester);

    expect(reported, (providerId: null, modelId: null));
  });

  testWidgets("a stored Default choice reads as its provider's Default entry", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: null));

    final field = tester.widget<DropdownButtonFormField<ModelChoice>>(
      find.byType(DropdownButtonFormField<ModelChoice>),
    );
    expect(field.initialValue, (providerId: testProviderId, modelId: null));
  });

  // A provider that names no default — a custom one added by hand, say — has
  // no Default entry, so a stored Default choice against it must read as the
  // null entry rather than as a value nothing renders.
  testWidgets("a Default choice against a provider with no default reads as None",
      (tester) async {
    const bareProvider = LlmProviderConfig(
      id: "bare",
      label: "Bare",
      api: LlmApi.openai,
      baseUrl: "https://bare.example/v1",
    );
    reported = null;
    app.backend.modelList = const [];
    await io(tester, () => app.seedProviders([bareProvider]));
    await app.pump(
      tester,
      Scaffold(
        body: ModelPicker(
          choice: (providerId: "bare", modelId: null),
          nullLabel: noneOptionLabel,
          onChanged: (c) => reported = c,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final field = tester.widget<DropdownButtonFormField<ModelChoice>>(
      find.byType(DropdownButtonFormField<ModelChoice>),
    );
    expect(field.initialValue, (providerId: null, modelId: null));
    expect(find.text(noneOptionLabel), findsOneWidget);
  });

  testWidgets("a model the backend no longer offers falls back to the Default entry",
      (tester) async {
    await pump(
      tester,
      choice: (providerId: testProviderId, modelId: "gone-1"),
      models: const [],
    );

    expect(tester.takeException(), isNull);
    final field = tester.widget<DropdownButtonFormField<ModelChoice>>(
      find.byType(DropdownButtonFormField<ModelChoice>),
    );
    expect(field.initialValue, (providerId: testProviderId, modelId: null));
  });

  testWidgets("reset puts a pick back on the provider default", (tester) async {
    await pump(tester, choice: (providerId: testProviderId, modelId: "claude-sonnet-4"));

    await tester.tap(find.byTooltip("Reset to Test - Default (glm-5.3-flash)"));
    await settleIo(tester);

    expect(reported, (providerId: testProviderId, modelId: null));
  });

  // The reset button is always live: pressed where the field already sits on
  // its target it rewrites the same value, and where a stored pair reads as
  // None — a provider removed under it — it is the cleanup.
  testWidgets("reset reports its target from None with a provider up", (tester) async {
    await pump(tester);

    final tooltip = "Reset to Test - Default (glm-5.3-flash)";
    await tester.tap(find.byTooltip(tooltip));
    await settleIo(tester);
    expect(reported, (providerId: testProviderId, modelId: null));
  });

  testWidgets("reset clears a stored pair nothing offers", (tester) async {
    reported = null;
    app.backend.modelList = const [];
    await app.pump(
      tester,
      Scaffold(
        body: ModelPicker(
          choice: (providerId: testProviderId, modelId: "gone-1"),
          nullLabel: noneOptionLabel,
          onChanged: (c) => reported = c,
        ),
      ),
    );

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
    await open(tester);
    expect(popupLabels(tester), contains("Default (Test · qwen-2.5)"));
  });

  testWidgets("the optional picker's Off text is its helper", (tester) async {
    await pump(
      tester,
      nullLabel: "Off",
      helperOffText: "Off, nothing happens.",
    );

    expect(find.text("Off, nothing happens."), findsOneWidget);
  });
}