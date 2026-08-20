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

  group("the categories", () {
    Finder tile(String label) => find.widgetWithText(ListTile, label);

    testWidgets("sit beside the page where there is room for them", (tester) async {
      useWindow(tester, const Size(1200, 800));
      await app.pump(tester, const SettingsPage());

      expect(find.byIcon(Icons.menu), findsNothing);
      expect(tile("Providers"), findsOneWidget);
      // Beside the list, so the page opens on a category as well as on them.
      expect(find.text("Default workspace"), findsOneWidget);
    });

    testWidgets("and are the page itself where there is not", (tester) async {
      await app.pump(tester, const SettingsPage());

      // The list is what settings opens on, and there is no hamburger because
      // there is no drawer to open.
      expect(tile("Providers"), findsOneWidget);
      expect(find.byIcon(Icons.menu), findsNothing);
      expect(find.byType(Drawer), findsNothing);
      expect(find.text("Default workspace"), findsNothing);
    });

    testWidgets("a category is then a page over it, left by the back key", (tester) async {
      final handlesBack = frameworkHandlesBack(tester);
      await app.pump(tester, const SettingsPage());

      await tester.tap(tile("Providers"));
      await settleIo(tester);
      expect(find.text("Add provider"), findsOneWidget);
      expect(find.byIcon(Icons.menu), findsNothing);

      // Pushing claims the key from Android, which is what makes the press
      // below one a device would actually deliver.
      expect(handlesBack.last, isTrue);
      expect(await pressBack(tester), isTrue);

      expect(find.text("Add provider"), findsNothing);
      expect(tile("Providers"), findsOneWidget);
    });

    testWidgets("widening puts the open category beside the list", (tester) async {
      useWindow(tester, const Size(800, 600));
      await app.pump(tester, const SettingsPage());

      await tester.tap(tile("LLMs"));
      await settleIo(tester);
      expect(tile("LLMs"), findsNothing);

      tester.view.physicalSize = const Size(1200, 800);
      await settleIo(tester);

      expect(tile("LLMs"), findsOneWidget);
      expect(find.text("New chats"), findsOneWidget);
    });

    testWidgets(
        "are offered General, Terminal, On-device, Voice, Assistant, Providers, "
        "LLMs, Data, in that order",
        (tester) async {
      useWindow(tester, const Size(1200, 800));
      await app.pump(tester, const SettingsPage());

      // Scoped to the panel: the settings beside it are tiles of their own.
      final panel = find.ancestor(of: tile("General"), matching: find.byType(ListView));
      expect(
        tester
            .widgetList<ListTile>(find.descendant(of: panel, matching: find.byType(ListTile)))
            .map((t) => (t.title! as Text).data),
        [
          "General",
          "Terminal",
          "On-device",
          "Voice",
          "Assistant",
          "Providers",
          "LLMs",
          "Data",
        ],
      );
    });
  });

  testWidgets("each category holds the settings filed under it", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.general);

    // scrollTo ends in ensureVisible, which throws unless the finder matches
    // exactly one widget — reaching each section is the assertion.
    await scrollTo(tester, find.text("Default workspace"));
    await scrollTo(tester, find.text("Appearance"));
    await scrollTo(tester, find.text("Agent"));
    await scrollTo(tester, find.text("Environment"));
    await scrollTo(tester, find.text("Delete all chats"));

    await openCategory(tester, SettingsCategory.llms);
    expect(find.text("New chats"), findsOneWidget);
    expect(find.text("Default workspace"), findsNothing);

    await openCategory(tester, SettingsCategory.providers);
    expect(find.text("Add provider"), findsOneWidget);
    expect(find.text("New chats"), findsNothing);
  });

  testWidgets("is one field, listing every provider's models", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.llms);
    expect(find.text("Provider"), findsNothing);

    await openDropdown(tester);
    expect(popupLabels(tester), [
      defaultOptionLabel,
      "Claude Haiku 3",
      "Claude Sonnet 4",
      "Llama 3",
      "Qwen 2.5",
    ]);
  });

  testWidgets("selecting a model persists it with its provider", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.llms);

    await openDropdown(tester);
    await tester.tap(find.text("Claude Sonnet 4").last);
    await settleIo(tester);

    final settings = app.container.read(appSettingsProvider);
    expect(settings.defaultProviderId, firstProvider);
    expect(settings.defaultModelId, "claude-sonnet-4");
    expect(
      File(app.config.settingsFile).readAsStringSync(),
      contains("claude-sonnet-4"),
    );
  });

  testWidgets("a persisted default is preselected", (tester) async {
    seedSettings(otherProvider, "qwen-2.5");
    await pumpSettings(tester, app, SettingsCategory.llms);

    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("a saved model the backend no longer offers does not break the page", (tester) async {
    seedSettings(otherProvider, "");
    await pumpSettings(tester, app, SettingsCategory.llms);

    expect(tester.takeException(), isNull);
    expect(find.text(defaultOptionLabel), findsOneWidget);
  });

  group("the title model", () {
    Future<void> openTitleDropdown(WidgetTester tester) async {
      // Scoped by the label that precedes it: the model picker above it is a
      // dropdown of the same type.
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
      await pumpSettings(tester, app, SettingsCategory.llms);
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
      await pumpSettings(tester, app, SettingsCategory.llms);
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
      await pumpSettings(tester, app, SettingsCategory.llms);
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
      await pumpSettings(tester, app, SettingsCategory.llms);

      expect(tester.takeException(), isNull);
      final titleLabel = find.text("Title LLM");
      final titleField = find.ancestor(
        of: titleLabel,
        matching: find.byType(LabelledField),
      );
      expect(find.descendant(of: titleField, matching: find.text("Off")), findsOneWidget);
    });
  });

  testWidgets("delete all chats asks first and then clears them", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.general);
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
    await pumpSettings(tester, app, SettingsCategory.general);
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
    await pumpSettings(tester, app, SettingsCategory.general);

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await settleIo(tester);

    expect(find.text("There are no chats to delete."), findsOneWidget);
    expect(find.text("Delete all"), findsNothing);
  });

  testWidgets("the reset button puts a pinned model back on Default", (tester) async {
    seedSettings(otherProvider, "qwen-2.5");
    await pumpSettings(tester, app, SettingsCategory.llms);
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
      await pumpSettings(tester, app, SettingsCategory.general);

      await addVariable(tester, "ANTHROPIC_API_KEY", "sk-test");

      expect(app.container.read(appSettingsProvider).environment, {"ANTHROPIC_API_KEY": "sk-test"});
      expect(AppSettings.load(app.config).environment, {"ANTHROPIC_API_KEY": "sk-test"});
    });

    testWidgets("the value is masked, so settings can be shown to someone", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await addVariable(tester, "OPENAI_API_KEY", "sk-secret");

      expect(find.text("OPENAI_API_KEY"), findsOneWidget);
      expect(find.text("sk-secret"), findsNothing);
    });

    testWidgets("editing a variable's name does not leave the old one behind", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await addVariable(tester, "OLD_NAME", "value");

      await tester.tap(find.text("OLD_NAME"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).first, "NEW_NAME");
      await tester.tap(find.text("Save"));
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).environment, {"NEW_NAME": "value"});
    });

    testWidgets("removing one leaves the rest", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await addVariable(tester, "KEEP", "1");
      await addVariable(tester, "DROP", "2");

      await tester.tap(find.byTooltip("Remove DROP"));
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).environment, {"KEEP": "1"});
    });

    testWidgets("the model default survives an environment edit", (tester) async {
      seedSettings(otherProvider, "qwen-2.5");
      await pumpSettings(tester, app, SettingsCategory.general);

      await addVariable(tester, "TOKEN", "abc");

      final settings = app.container.read(appSettingsProvider);
      expect(settings.defaultProviderId, otherProvider);
      expect(settings.defaultModelId, "qwen-2.5");
    });
  });
}