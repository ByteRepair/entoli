import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/widgets/model_picker.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";
import "../harness.dart";

/// The rules both settings pages inherit, tested once on the widget that owns
/// them rather than twice through the pages.
void main() {
  late TestApp app;
  ModelChoice? reported;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pump(
    WidgetTester tester, {
    ModelChoice choice = (providerId: null, modelId: null),
    ModelChoice? inherited,
    List<ModelOption> models = testModels,
  }) async {
    reported = null;
    app.backend.modelList = models;
    await app.pump(
      tester,
      Scaffold(
        body: ModelPicker(
          choice: choice,
          inherited: inherited,
          onChanged: (c) => reported = c,
        ),
      ),
    );
  }

  testWidgets("Default leads the list, every model behind it and sorted", (tester) async {
    await pump(tester);

    await openDropdown(tester);
    expect(popupLabels(tester), [
      defaultOptionLabel,
      "Claude Haiku 3",
      "Claude Sonnet 4",
      "Llama 3",
      "Qwen 2.5",
    ]);
  });

  testWidgets("picking a model reports the provider that offers it", (tester) async {
    await pump(tester);

    await openDropdown(tester);
    await tester.tap(find.text("Claude Sonnet 4").last);
    await settleIo(tester);

    expect(reported, (providerId: "anthropic", modelId: "claude-sonnet-4"));
  });

  testWidgets("picking Default clears both halves", (tester) async {
    await pump(tester, choice: (providerId: "ollama-cloud", modelId: "qwen-2.5"));

    await openDropdown(tester);
    await tester.tap(find.text(defaultOptionLabel).last);
    await settleIo(tester);

    expect(reported, (providerId: null, modelId: null));
  });

  testWidgets("a model stored without its provider is still selected", (tester) async {
    await pump(tester, choice: (providerId: null, modelId: "qwen-2.5"));

    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("a model the backend no longer offers reads as Default", (tester) async {
    await pump(tester, choice: (providerId: "anthropic", modelId: "gone-1"));

    expect(tester.takeException(), isNull);
    final field = tester.widget<DropdownButtonFormField<ModelOption?>>(
      find.byType(DropdownButtonFormField<ModelOption?>),
    );
    expect(field.initialValue, isNull);
  });

  testWidgets("Default names what it resolves to", (tester) async {
    await pump(tester, inherited: (providerId: "ollama-cloud", modelId: "qwen-2.5"));

    expect(find.text("Using Qwen 2.5"), findsOneWidget);
  });

  testWidgets("with no inherited value either, Default names the backend", (tester) async {
    await pump(tester);

    expect(find.text("Using the backend default"), findsOneWidget);
  });

  testWidgets("resetting clears both halves", (tester) async {
    await pump(tester, choice: (providerId: "ollama-cloud", modelId: "qwen-2.5"));

    await tester.tap(find.byTooltip("Reset to $defaultOptionLabel"));
    await settleIo(tester);

    expect(reported, (providerId: null, modelId: null));
  });

  testWidgets("no models at all says so", (tester) async {
    await pump(tester, models: const []);

    expect(find.text("No models available."), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<ModelOption?>), findsNothing);
  });
}
