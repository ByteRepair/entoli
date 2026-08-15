import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/widgets/provider_model_selector.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";
import "../harness.dart";

/// The rules both settings pages inherit, tested once on the widget that owns
/// them rather than twice through the pages.
void main() {
  ModelChoice? reported;

  Future<void> pump(
    WidgetTester tester, {
    ModelChoice choice = (providerId: null, modelId: null),
    ModelChoice? inherited,
    List<ModelOption> models = testModels,
  }) async {
    reported = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProviderModelSelector(
          models: models,
          choice: choice,
          inherited: inherited,
          onChanged: (c) => reported = c,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets("Default leads both lists, the rest sorted", (tester) async {
    await pump(tester, inherited: (providerId: "ollama-cloud", modelId: null));

    await openDropdown(tester, model: false);
    expect(popupLabels(tester), [defaultOptionLabel, "anthropic", "ollama-cloud"]);
    await tester.tap(find.text(defaultOptionLabel).last);
    await tester.pumpAndSettle();

    await openDropdown(tester, model: true);
    expect(popupLabels(tester), [defaultOptionLabel, "Llama 3", "Qwen 2.5"]);
  });

  testWidgets("with nothing to inherit, no models are guessed at", (tester) async {
    await pump(tester);

    await openDropdown(tester, model: true);
    expect(popupLabels(tester), [defaultOptionLabel]);
  });

  testWidgets("picking a model reports the provider that offers it", (tester) async {
    await pump(tester, choice: (providerId: "anthropic", modelId: null));

    await openDropdown(tester, model: true);
    await tester.tap(find.text("Claude Sonnet 4"));
    await tester.pumpAndSettle();

    expect(reported, (providerId: "anthropic", modelId: "claude-sonnet-4"));
  });

  testWidgets("switching provider drops a model it does not offer", (tester) async {
    await pump(tester, choice: (providerId: "ollama-cloud", modelId: "qwen-2.5"));

    await openDropdown(tester, model: false);
    await tester.tap(find.text("anthropic").last);
    await tester.pumpAndSettle();

    expect(reported, (providerId: "anthropic", modelId: null));
  });

  testWidgets("switching provider keeps a model it still offers", (tester) async {
    const shared = [
      ModelOption(providerId: "a", modelId: "shared", label: "Shared"),
      ModelOption(providerId: "b", modelId: "shared", label: "Shared"),
    ];
    await pump(tester, choice: (providerId: "a", modelId: "shared"), models: shared);

    await openDropdown(tester, model: false);
    await tester.tap(find.text("b").last);
    await tester.pumpAndSettle();

    expect(reported, (providerId: "b", modelId: "shared"));
  });

  testWidgets("a model stored without its provider still shows both", (tester) async {
    await pump(tester, choice: (providerId: null, modelId: "qwen-2.5"));

    expect(find.text("ollama-cloud"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("a model the backend no longer offers reads as Default", (tester) async {
    await pump(tester, choice: (providerId: "anthropic", modelId: "gone-1"));

    expect(tester.takeException(), isNull);
    final modelField = tester.widget<DropdownButtonFormField<String?>>(
      find.byType(DropdownButtonFormField<String?>).last,
    );
    expect(modelField.initialValue, isNull);
  });

  testWidgets("each field names what Default resolves to", (tester) async {
    await pump(tester, inherited: (providerId: "ollama-cloud", modelId: "qwen-2.5"));

    expect(find.text("Using ollama-cloud"), findsOneWidget);
    expect(find.text("Using Qwen 2.5"), findsOneWidget);
  });

  testWidgets("with no inherited value either, Default names the backend", (tester) async {
    await pump(tester);

    expect(find.text("Using the backend default"), findsNWidgets(2));
  });

  testWidgets("resetting the provider clears both halves", (tester) async {
    await pump(tester, choice: (providerId: "ollama-cloud", modelId: "qwen-2.5"));

    await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").first);
    await tester.pumpAndSettle();

    expect(reported, (providerId: null, modelId: null));
  });

  testWidgets("resetting the model keeps the provider", (tester) async {
    await pump(tester, choice: (providerId: "ollama-cloud", modelId: "qwen-2.5"));

    await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").last);
    await tester.pumpAndSettle();

    expect(reported, (providerId: "ollama-cloud", modelId: null));
  });

  testWidgets("no models at all says so", (tester) async {
    await pump(tester, models: const []);

    expect(find.text("No models available."), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String?>), findsNothing);
  });
}
