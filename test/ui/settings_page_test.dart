import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
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

  testWidgets("renders a section per thing that can be configured", (tester) async {
    await pumpSettings(tester);
    expect(find.text("Settings"), findsOneWidget);
    expect(find.text("New chats"), findsOneWidget);
    expect(find.text("Default backend"), findsOneWidget);

    await scrollTo(tester, find.text("Built-in harness"));
    expect(find.text("Built-in harness"), findsOneWidget);
    await scrollTo(tester, find.text("Environment"));
    expect(find.text("Environment"), findsOneWidget);
  });

  group("a platform with only the built-in harness", () {
    setUp(() => app = TestApp.create(backends: const [BackendKind.miniswe]));

    testWidgets("never offers opencode", (tester) async {
      await pumpSettings(tester);

      expect(find.text("Default backend"), findsNothing);
      expect(find.byType(DropdownButtonFormField<BackendKind?>), findsNothing);
      expect(find.text("OpenCode"), findsNothing);
    });

    testWidgets("does not describe the environment as opencode's", (tester) async {
      await pumpSettings(tester);
      await scrollTo(tester, find.text("Environment"));

      expect(find.textContaining("opencode"), findsNothing);
      expect(find.textContaining("built-in harness"), findsWidgets);
    });
  });

  testWidgets("the default backend is the platform's until one is chosen", (tester) async {
    await pumpSettings(tester);
    expect(find.text("$defaultOptionLabel (OpenCode)"), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<BackendKind?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Built-in harness").last);
    await tester.pumpAndSettle();

    expect(app.container.read(appSettingsProvider).defaultBackend, BackendKind.miniswe);
    expect(AppSettings.load(app.config).defaultBackend, BackendKind.miniswe);
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

    await scrollTo(tester, find.text("Delete all chats"));
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

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();

    expect(await repo.listChats(), hasLength(1));
  });

  testWidgets("with no chats there is nothing to confirm", (tester) async {
    await pumpSettings(tester);

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await tester.pumpAndSettle();

    expect(find.text("There are no chats to delete."), findsOneWidget);
    expect(find.text("Delete all"), findsNothing);
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

  group("environment", () {
    Future<void> addVariable(WidgetTester tester, String name, String value) async {
      await scrollTo(tester, find.text("Add variable"));
      await tester.tap(find.text("Add variable"));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, name);
      await tester.enterText(find.byType(TextField).last, value);
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();
    }

    testWidgets("a variable added here reaches the next server", (tester) async {
      await pumpSettings(tester);

      await addVariable(tester, "ANTHROPIC_API_KEY", "sk-test");

      expect(app.container.read(appSettingsProvider).opencodeEnv, {"ANTHROPIC_API_KEY": "sk-test"});
      expect(AppSettings.load(app.config).opencodeEnv, {"ANTHROPIC_API_KEY": "sk-test"});
    });

    testWidgets("the value is masked, so settings can be shown to someone", (tester) async {
      await pumpSettings(tester);
      await addVariable(tester, "OPENAI_API_KEY", "sk-secret");

      expect(find.text("OPENAI_API_KEY"), findsOneWidget);
      expect(find.text("sk-secret"), findsNothing);
    });

    testWidgets("editing a variable's name does not leave the old one behind", (tester) async {
      await pumpSettings(tester);
      await addVariable(tester, "OLD_NAME", "value");

      await tester.tap(find.text("OLD_NAME"));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, "NEW_NAME");
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();

      expect(app.container.read(appSettingsProvider).opencodeEnv, {"NEW_NAME": "value"});
    });

    testWidgets("removing one leaves the rest", (tester) async {
      await pumpSettings(tester);
      await addVariable(tester, "KEEP", "1");
      await addVariable(tester, "DROP", "2");

      await tester.tap(find.byTooltip("Remove DROP"));
      await tester.pumpAndSettle();

      expect(app.container.read(appSettingsProvider).opencodeEnv, {"KEEP": "1"});
    });

    testWidgets("the model default survives an environment edit", (tester) async {
      seedSettings(otherProvider, "qwen-2.5");
      await pumpSettings(tester);

      await addVariable(tester, "TOKEN", "abc");

      final settings = app.container.read(appSettingsProvider);
      expect(settings.defaultProviderId, otherProvider);
      expect(settings.defaultModelId, "qwen-2.5");
    });
  });
}