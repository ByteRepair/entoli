import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  // Providers are listed alphabetically, so "anthropic" is the one preselected
  // when nothing is persisted.
  const firstProvider = "anthropic";
  const otherProvider = "ollama-cloud";

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  void seedSettings(String providerId, String modelId) =>
      app.seedGlobalDefault(providerId: providerId, modelId: modelId);

  Future<void> pumpSettings(WidgetTester tester) => app.pump(tester, const SettingsPage());

  testWidgets("renders default backend and OpenCode section", (tester) async {
    await pumpSettings(tester);
    expect(find.text("Settings"), findsOneWidget);
    expect(find.text("Default backend"), findsOneWidget);
    expect(find.text("OpenCode"), findsOneWidget);
  });

  testWidgets("shows both provider and model form fields", (tester) async {
    await pumpSettings(tester);
    expect(find.text("Provider"), findsOneWidget);
    expect(find.text("Model"), findsOneWidget);
  });

  testWidgets("with nothing persisted, Default offers no models to guess from", (tester) async {
    await pumpSettings(tester);
    expect(find.byType(DropdownButtonFormField<String?>), findsNWidgets(2));
    expect(find.text(defaultOptionLabel), findsNWidgets(2));

    await openDropdown(tester, model: true);

    // Default means the backend decides; picking a provider is what populates
    // this list, rather than an arbitrary first one.
    expect(popupLabels(tester), [defaultOptionLabel]);
  });

  testWidgets("choosing a provider populates the models", (tester) async {
    await pumpSettings(tester);

    await openDropdown(tester, model: false);
    await tester.tap(find.text(firstProvider).last);
    await tester.pumpAndSettle();

    await openDropdown(tester, model: true);
    expect(popupLabels(tester), [defaultOptionLabel, "Claude Haiku 3", "Claude Sonnet 4"]);
  });

  testWidgets("selecting a model persists default in settings", (tester) async {
    await pumpSettings(tester);
    await openDropdown(tester, model: false);
    await tester.tap(find.text(firstProvider).last);
    await tester.pumpAndSettle();

    await openDropdown(tester, model: true);
    await tester.tap(find.text("Claude Sonnet 4"));
    await tester.pumpAndSettle();

    final settings = app.container.read(appSettingsProvider);
    expect(settings.defaultProviderId, firstProvider);
    expect(settings.defaultModelId, "claude-sonnet-4");
    expect(
      app.config.settingsFile.readAsStringSync(),
      contains("claude-sonnet-4"),
    );
  });

  testWidgets("switching provider updates model list", (tester) async {
    await pumpSettings(tester);
    await openDropdown(tester, model: false);

    await tester.tap(find.text(otherProvider));
    await tester.pumpAndSettle();

    await openDropdown(tester, model: true);

    expect(find.text("Llama 3"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsOneWidget);
    expect(find.text("Claude Sonnet 4"), findsNothing);
    expect(find.text("Claude Haiku 3"), findsNothing);
  });

  testWidgets("persisted default is preselected and cleared when provider changes", (tester) async {
    seedSettings(otherProvider, "qwen-2.5");
    await pumpSettings(tester);

    expect(find.text(otherProvider), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsOneWidget);

    await openDropdown(tester, model: false);
    await tester.tap(find.text(firstProvider));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text("Qwen 2.5"), findsNothing);
    expect(find.text(defaultOptionLabel), findsOneWidget);
  });

  testWidgets("a saved model the backend no longer offers does not break the page", (tester) async {
    seedSettings(otherProvider, "");
    await pumpSettings(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(otherProvider), findsOneWidget);
    expect(find.text(defaultOptionLabel), findsOneWidget);
  });

  testWidgets("delete all chats asks first and then clears them", (tester) async {
    await pumpSettings(tester);
    final repo = app.repo;
    await repo.createChat(title: "one");
    await repo.createChat(title: "two");

    await tester.tap(find.text("Delete all chats"));
    await tester.pumpAndSettle();
    expect(find.textContaining("permanently removes 2 chats"), findsOneWidget);

    await tester.tap(find.text("Delete all"));
    await tester.pumpAndSettle();

    expect(await repo.listChats(), isEmpty);
  });

  testWidgets("cancelling the confirmation keeps the chats", (tester) async {
    await pumpSettings(tester);
    final repo = app.repo;
    await repo.createChat(title: "one");

    await tester.tap(find.text("Delete all chats"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();

    expect(await repo.listChats(), hasLength(1));
  });

  testWidgets("with no chats there is nothing to confirm", (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text("Delete all chats"));
    await tester.pumpAndSettle();

    expect(find.text("There are no chats to delete."), findsOneWidget);
    expect(find.text("Delete all"), findsNothing);
  });

  testWidgets("providers and models are listed alphabetically", (tester) async {
    await pumpSettings(tester);

    await openDropdown(tester, model: false);
    expect(popupLabels(tester), [defaultOptionLabel, firstProvider, otherProvider]);
    await tester.tap(find.text(firstProvider).last);
    await tester.pumpAndSettle();

    await openDropdown(tester, model: true);
    expect(popupLabels(tester),
        [defaultOptionLabel, "Claude Haiku 3", "Claude Sonnet 4"]);
  });

  testWidgets("the reset button puts a pinned model back on Default", (tester) async {
    seedSettings(otherProvider, "qwen-2.5");
    await pumpSettings(tester);
    expect(find.text("Qwen 2.5"), findsOneWidget);

    await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").last);
    await tester.pumpAndSettle();

    expect(app.container.read(appSettingsProvider).defaultModelId, isNull);
    expect(find.text("Qwen 2.5"), findsNothing);
  });
}