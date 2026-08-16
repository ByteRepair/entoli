import "dart:io";

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

    // scrollTo ends in ensureVisible, which throws unless the finder matches
    // exactly one widget — reaching each section is the assertion.
    await scrollTo(tester, find.text("Default workspace"));
    await scrollTo(tester, find.text("Agent"));
    await scrollTo(tester, find.text("Environment"));
    await scrollTo(tester, find.text("Delete all chats"));
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
    await settleIo(tester);

    await openDropdown(tester, model: true);
    expect(popupLabels(tester), [defaultOptionLabel, "Claude Haiku 3", "Claude Sonnet 4"]);
  });

  testWidgets("selecting a model persists default in settings", (tester) async {
    await pumpSettings(tester);
    await openDropdown(tester, model: false);
    await tester.tap(find.text(firstProvider).last);
    await settleIo(tester);

    await openDropdown(tester, model: true);
    await tester.tap(find.text("Claude Sonnet 4"));
    await settleIo(tester);

    final settings = app.container.read(appSettingsProvider);
    expect(settings.defaultProviderId, firstProvider);
    expect(settings.defaultModelId, "claude-sonnet-4");
    expect(
      File(app.config.settingsFile).readAsStringSync(),
      contains("claude-sonnet-4"),
    );
  });

  testWidgets("switching provider updates model list", (tester) async {
    await pumpSettings(tester);
    await openDropdown(tester, model: false);

    await tester.tap(find.text(otherProvider));
    await settleIo(tester);

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
    await settleIo(tester);

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

  group("the title model", () {
    Future<void> openTitleDropdown(WidgetTester tester) async {
      // The title picker is the first OptionalModelPicker on the page; the
      // classifier picker is the second. Both are the same type, so scope by
      // the label that precedes it.
      final label = find.text("Title LLM");
      await scrollTo(tester, label);
      final field = find.descendant(
        of: find.ancestor(of: label, matching: find.byType(LabelledField)),
        matching: find.byType(DropdownButtonFormField<ModelOption?>),
      );
      await tester.tap(field);
      await settleIo(tester);
    }

    testWidgets("is off until one is picked, and every model is offered", (tester) async {
      await pumpSettings(tester);
      await openTitleDropdown(tester);

      // Off, then all four models by name: nothing inherits from this, so
      // there is no provider to narrow the list to.
      expect(popupLabels(tester), [
        "Off",
        "Claude Haiku 3",
        "Claude Sonnet 4",
        "Llama 3",
        "Qwen 2.5",
      ]);
    });

    testWidgets("picking one stores the provider with it", (tester) async {
      await pumpSettings(tester);
      await openTitleDropdown(tester);

      await tester.tap(find.text("Claude Haiku 3").last);
      await settleIo(tester);

      final settings = app.container.read(appSettingsProvider);
      expect(settings.titleProviderId, firstProvider);
      expect(settings.titleModelId, "claude-haiku-3");
      expect(AppSettings.load(app.config).titleModelId, "claude-haiku-3");
    });

    testWidgets("turning it off drops both halves", (tester) async {
      app.seedSettings(
          AppSettings(titleProviderId: otherProvider, titleModelId: "qwen-2.5"));
      await pumpSettings(tester);
      expect(find.text("Qwen 2.5"), findsOneWidget);

      await openTitleDropdown(tester);
      await tester.tap(find.text("Off").last);
      await settleIo(tester);

      final settings = app.container.read(appSettingsProvider);
      expect(settings.titleProviderId, isNull);
      expect(settings.titleModelId, isNull);
    });

    testWidgets("a model the backend no longer offers reads as off", (tester) async {
      app.seedSettings(AppSettings(titleProviderId: "gone", titleModelId: "vanished"));
      await pumpSettings(tester);

      expect(tester.takeException(), isNull);
      // The title LLM reads as off; the classifier LLM is also off, so scope
      // to the title field.
      final titleLabel = find.text("Title LLM");
      final titleField = find.ancestor(
        of: titleLabel,
        matching: find.byType(LabelledField),
      );
      expect(find.descendant(of: titleField, matching: find.text("Off")), findsOneWidget);
    });
  });

  testWidgets("delete all chats asks first and then clears them", (tester) async {
    await pumpSettings(tester);
    final repo = app.repo;
    await io(tester, () => app.seedChat(title: "one"));
    await io(tester, () => app.seedChat(title: "two"));

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await settleIo(tester);
    expect(find.textContaining("permanently removes 2 chats"), findsOneWidget);

    await tester.tap(find.text("Delete all"));
    await settleIo(tester);

    expect(await io(tester, () => repo.listChats()), isEmpty);
  });

  testWidgets("cancelling the confirmation keeps the chats", (tester) async {
    await pumpSettings(tester);
    final repo = app.repo;
    await io(tester, () => app.seedChat(title: "one"));

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await settleIo(tester);
    await tester.tap(find.text("Cancel"));
    await settleIo(tester);

    expect(await io(tester, () => repo.listChats()), hasLength(1));
  });

  testWidgets("with no chats there is nothing to confirm", (tester) async {
    await pumpSettings(tester);

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await settleIo(tester);

    expect(find.text("There are no chats to delete."), findsOneWidget);
    expect(find.text("Delete all"), findsNothing);
  });

  testWidgets("the reset button puts a pinned model back on Default", (tester) async {
    seedSettings(otherProvider, "qwen-2.5");
    await pumpSettings(tester);
    expect(find.text("Qwen 2.5"), findsOneWidget);

    await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").last);
    await settleIo(tester);

    expect(app.container.read(appSettingsProvider).defaultModelId, isNull);
    expect(find.text("Qwen 2.5"), findsNothing);
  });

  group("environment", () {
    Future<void> addVariable(WidgetTester tester, String name, String value) async {
      await scrollTo(tester, find.text("Add variable"));
      await tester.tap(find.text("Add variable"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).first, name);
      await tester.enterText(find.byType(TextField).last, value);
      await tester.tap(find.text("Save"));
      await settleIo(tester);
    }

    testWidgets("a variable added here reaches the next server", (tester) async {
      await pumpSettings(tester);

      await addVariable(tester, "ANTHROPIC_API_KEY", "sk-test");

      expect(app.container.read(appSettingsProvider).environment, {"ANTHROPIC_API_KEY": "sk-test"});
      expect(AppSettings.load(app.config).environment, {"ANTHROPIC_API_KEY": "sk-test"});
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
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).first, "NEW_NAME");
      await tester.tap(find.text("Save"));
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).environment, {"NEW_NAME": "value"});
    });

    testWidgets("removing one leaves the rest", (tester) async {
      await pumpSettings(tester);
      await addVariable(tester, "KEEP", "1");
      await addVariable(tester, "DROP", "2");

      await tester.tap(find.byTooltip("Remove DROP"));
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).environment, {"KEEP": "1"});
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