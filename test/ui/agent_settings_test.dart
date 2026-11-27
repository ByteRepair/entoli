import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:entoli_core/agent/llm/llm_client.dart" show LlmException;
import "package:entoli_core/model/app_settings.dart";
import "package:entoli_core/model/llm_provider.dart";
import "package:entoli_core/model/permission.dart";
import "package:entoli_core/model/project_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/provider_picker.dart"
    show CardBox, ProviderCard, ProviderPickerPage;
import "package:agent_chat/ui/settings/settings_category.dart";
import "package:agent_chat/ui/widgets/toggle_chip.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// Open the picker behind the Add provider button and choose an entry.
  Future<void> addProvider(WidgetTester tester, String entry) async {
    await scrollTo(tester, find.text("Add provider"));
    await tester.tap(find.text("Add provider"));
    await settleIo(tester);
    await tester.ensureVisible(find.text(entry).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(entry).last);
    await settleIo(tester);
  }

  /// Press a provider's X and answer its confirmation.
  Future<void> removeProvider(
    WidgetTester tester,
    String name, {
    bool confirm = true,
  }) async {
    await scrollTo(tester, find.byTooltip("Remove $name"));
    await tester.tap(find.byTooltip("Remove $name"));
    await tester.pumpAndSettle();
    expect(find.text("Remove $name?"), findsOneWidget);
    await tester.tap(find.text(confirm ? "Remove" : "Cancel"));
    await settleIo(tester);
  }

  Future<void> openAdvanced(WidgetTester tester) async {
    await tester.ensureVisible(find.text("Advanced"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Advanced"));
    await tester.pumpAndSettle();
  }

  /// Save, once the last answer typed is drawn: Save waits on the form.
  Future<void> saveDialog(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.text("Save"));
    await settleIo(tester);
  }

  /// A field of the open dialog by its label. Indexed finds would be wrong
  /// whenever something with a TextField sits behind the dialog — the
  /// recommended-provider card's key box does.
  Finder dialogField(String label) => find.widgetWithText(TextField, label);

  List<LlmProviderConfig> saved() =>
      app.container.read(appSettingsProvider).llmProviders;

  /// The key stored for the provider called [name].
  String? keyOf(String name) => app.secrets.providerKey(
    saved().firstWhere((p) => p.displayName == name).id,
  );

  group("providers", () {
    testWidgets("says plainly that nothing is configured yet", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);

      expect(
        find.textContaining("cannot answer until one is added"),
        findsOneWidget,
      );
    });

    testWidgets(
      "a preset asks for the key alone, its endpoint filled in under Advanced",
      (tester) async {
        await pumpSettings(tester, app, SettingsCategory.providers);
        await addProvider(tester, "Ollama Cloud");

        expect(find.text("Get a key from Ollama Cloud"), findsOneWidget);
        expect(find.text("Ollama Cloud's privacy policy"), findsOneWidget);
        expect(dialogField("Base URL"), findsNothing);
        expect(dialogField("API key"), findsNothing);

        await openAdvanced(tester);
        expect(find.text("ollama-cloud"), findsOneWidget);
        expect(find.text("https://ollama.com/v1"), findsOneWidget);

        await tester.enterText(dialogField("Access key"), "sk-ollama");
        await saveDialog(tester);

        expect(saved().single.displayName, "Ollama Cloud");
        expect(saved().single.catalogId, "ollama-cloud");
        expect(saved().single.baseUrl, "https://ollama.com/v1");
        // The key went to the store; no config carries one.
        expect(keyOf("Ollama Cloud"), "sk-ollama");
      },
    );

    testWidgets("a local preset asks for nothing", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Ollama (local)");

      expect(find.textContaining("nothing to type"), findsOneWidget);
      expect(dialogField("Access key"), findsNothing);
      await saveDialog(tester);

      expect(saved().single.catalogId, "ollama");
    });

    testWidgets("a custom endpoint starts empty and is typed in", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Custom endpoint");

      await tester.enterText(dialogField("Name"), "vllm");
      await tester.enterText(
        dialogField("Base URL"),
        "http://gpu.local:8000/v1",
      );
      await tester.enterText(
        dialogField("Models endpoint"),
        "http://gpu.local:8000/v1/models",
      );
      await saveDialog(tester);

      expect(saved().single.displayName, "vllm");
      expect(saved().single.catalogId, isNull);
      expect(saved().single.baseUrl, "http://gpu.local:8000/v1");
      expect(saved().single.modelsEndpoint, "http://gpu.local:8000/v1/models");
      expect(saved().single.api, LlmApi.openai);
    });

    testWidgets("one missing its name or URL is not saved", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Custom endpoint");

      await tester.enterText(dialogField("Name"), "nameless");
      await saveDialog(tester);

      expect(saved(), isEmpty);
    });

    testWidgets("the key is never shown back on the page", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Anthropic");
      await tester.enterText(dialogField("Access key"), "sk-ant-secret");
      await saveDialog(tester);

      expect(find.text("sk-ant-secret"), findsNothing);
      // The row says it can answer, never with which key.
      expect(find.text("Connected"), findsOneWidget);
    });

    testWidgets("one with no key says it needs one", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Anthropic");
      await saveDialog(tester);

      expect(find.text("Needs a key"), findsOneWidget);
    });

    testWidgets(
      "one reading its key from the settings' environment is connected",
      (tester) async {
        await pumpSettings(tester, app, SettingsCategory.providers);
        await io(
          tester,
          () => app.container.read(appSettingsProvider.notifier).setEnvironment(
            const {"ANTHROPIC_API_KEY": "sk-env"},
          ),
        );
        await addProvider(tester, "Anthropic");
        await saveDialog(tester);

        expect(find.text("Connected"), findsOneWidget);
      },
    );

    testWidgets("an endpoint typed in by hand is told apart by its address", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Custom endpoint");
      await tester.enterText(dialogField("Name"), "vllm");
      await tester.enterText(
        dialogField("Base URL"),
        "http://gpu.local:8000/v1",
      );
      await saveDialog(tester);

      expect(
        find.text("http://gpu.local:8000/v1 · Needs a key"),
        findsOneWidget,
      );
    });

    testWidgets(
      "a key the provider refuses keeps the dialog open, and can be saved anyway",
      (tester) async {
        app.dispose();
        app = TestApp.create(acceptsKey: (key) async => key == "sk-good");
        await pumpSettings(tester, app, SettingsCategory.providers);
        await addProvider(tester, "OpenAI");
        await tester.enterText(dialogField("Access key"), "sk-typo");
        await saveDialog(tester);

        expect(find.textContaining("did not accept this key"), findsOneWidget);
        expect(saved(), isEmpty);

        await tester.tap(find.text("Save anyway"));
        await settleIo(tester);
        expect(keyOf("OpenAI"), "sk-typo");
      },
    );

    testWidgets("typing again after a refusal checks the new key", (
      tester,
    ) async {
      app.dispose();
      app = TestApp.create(acceptsKey: (key) async => key == "sk-good");
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await tester.enterText(dialogField("Access key"), "sk-typo");
      await saveDialog(tester);
      await tester.enterText(dialogField("Access key"), "sk-good");
      await tester.pump();
      expect(find.text("Save anyway"), findsNothing);
      await saveDialog(tester);

      expect(keyOf("OpenAI"), "sk-good");
    });

    testWidgets("a provider that could not be asked does not stop the save", (
      tester,
    ) async {
      app.dispose();
      app = TestApp.create(
        acceptsKey: (_) async =>
            throw const LlmException("offline", retryable: true),
      );
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await tester.enterText(dialogField("Access key"), "sk-o");
      await saveDialog(tester);

      expect(keyOf("OpenAI"), "sk-o");
    });

    testWidgets(
      "a preset already configured is added again under a name of its own",
      (tester) async {
        await pumpSettings(tester, app, SettingsCategory.providers);
        for (var i = 0; i < 3; i++) {
          await addProvider(tester, "Groq");
          await saveDialog(tester);
        }

        expect(saved().map((p) => p.displayName), [
          "Groq",
          "Groq-02",
          "Groq-03",
        ]);
        expect(saved().map((p) => p.catalogId), ["groq", "groq", "groq"]);
        expect(saved().map((p) => p.id).toSet(), hasLength(3));

        await addProvider(tester, "Groq");
        await tester.enterText(dialogField("Name"), "Groq");
        await tester.pump();
        expect(find.text("Another provider is called Groq"), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, "Save"))
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets(
      "a free tier paid for in privacy is accepted before its key is asked",
      (tester) async {
        await pumpSettings(tester, app, SettingsCategory.providers);
        await addProvider(tester, "Google Gemini");

        expect(find.textContaining("free tier is not private"), findsOneWidget);
        expect(dialogField("Access key"), findsNothing);
        expect(find.widgetWithText(FilledButton, "Save"), findsNothing);

        await tester.tap(find.text("I understand, add it"));
        await settleIo(tester);
        await tester.enterText(dialogField("Access key"), "gm-secret");
        await saveDialog(tester);

        expect(saved().single.catalogId, "google");
      },
    );

    testWidgets("a provider with no free tier is not warned about", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Anthropic");

      expect(find.textContaining("free tier is not private"), findsNothing);
      expect(dialogField("Access key"), findsOneWidget);
    });

    testWidgets("editing one replaces it rather than adding another", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await saveDialog(tester);

      await tester.tap(find.text("OpenAI"));
      await settleIo(tester);
      await openAdvanced(tester);
      await tester.enterText(dialogField("Base URL"), "https://proxy.local/v1");
      await saveDialog(tester);

      expect(saved(), hasLength(1));
      expect(saved().single.baseUrl, "https://proxy.local/v1");
    });

    testWidgets("removing one leaves the rest", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await saveDialog(tester);
      await addProvider(tester, "Groq");
      await saveDialog(tester);

      await removeProvider(tester, "Groq", confirm: false);
      expect(saved().map((p) => p.displayName), ["OpenAI", "Groq"]);

      await removeProvider(tester, "Groq");
      expect(saved().map((p) => p.displayName), ["OpenAI"]);
    });

    testWidgets("backing out of a sign-in is back to the picker", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Groq");
      await tester.tap(find.text("Cancel"));
      await settleIo(tester);
      expect(find.byType(ProviderPickerPage), findsOneWidget);

      await tester.tap(find.text("Groq").last);
      await settleIo(tester);
      await saveDialog(tester);
      expect(find.byType(ProviderPickerPage), findsNothing);
      expect(saved().map((p) => p.displayName), ["Groq"]);
    });

    testWidgets("Escape leaves the picker", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await tester.tap(find.text("Add provider"));
      await settleIo(tester);
      expect(find.byType(ProviderPickerPage), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ProviderPickerPage), findsNothing);
    });

    testWidgets("the picker narrows to every tag and any company picked", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await tester.tap(find.text("Add provider"));
      await settleIo(tester);
      Finder card(String name) =>
          find.widgetWithText(ProviderCard, name, skipOffstage: false);
      Future<void> toggle(String chip) async {
        await tester.tap(find.widgetWithText(ToggleChip, chip));
        await tester.pumpAndSettle();
      }

      final cards = find.byType(CardBox, skipOffstage: false);
      expect(
        {for (final card in cards.evaluate()) card.size},
        hasLength(1),
        reason: "every card one size",
      );

      expect(card("Groq"), findsOneWidget);
      expect(find.text("Custom endpoint", skipOffstage: false), findsOneWidget);

      await toggle("Free");
      expect(card("Groq"), findsNothing);
      expect(card("Google Gemini"), findsOneWidget);
      expect(find.text("Custom endpoint", skipOffstage: false), findsNothing);

      await toggle("Private");
      expect(find.byType(ProviderCard, skipOffstage: false), findsNothing);
      expect(find.text("No provider is all of these."), findsOneWidget);

      await toggle("Free");
      await toggle("Private");
      await toggle("Ollama");
      expect(card("Ollama Cloud"), findsOneWidget);
      expect(card("Ollama (local)"), findsOneWidget);
      expect(card("Groq"), findsNothing);
    });

    testWidgets("adding one refreshes what the model picker can offer", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      final before = app.container.read(availableModelsProvider);
      await addProvider(tester, "Anthropic");
      await saveDialog(tester);

      // Invalidated rather than left showing a list built before the provider
      // existed.
      expect(
        identical(before, app.container.read(availableModelsProvider)),
        isFalse,
      );
    });

    testWidgets("removing one takes its stored key with it", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await tester.enterText(dialogField("Access key"), "sk-o");
      await saveDialog(tester);
      final id = saved().single.id;
      expect(app.secrets.providerKey(id), "sk-o");

      await removeProvider(tester, "OpenAI");

      expect(app.secrets.providerKey(id), isNull);
    });

    testWidgets("editing one with a stored key, saving empty, keeps the key", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await tester.enterText(dialogField("Access key"), "sk-o");
      await saveDialog(tester);

      await tester.tap(find.text("OpenAI"));
      await settleIo(tester);
      await saveDialog(tester);

      expect(keyOf("OpenAI"), "sk-o");
    });

    testWidgets("renaming one keeps its id, and so its key", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Custom endpoint");
      await tester.enterText(dialogField("Name"), "vllm");
      await tester.enterText(
        dialogField("Base URL"),
        "http://gpu.local:8000/v1",
      );
      await tester.enterText(dialogField("API key"), "sk-v");
      await saveDialog(tester);
      final id = saved().single.id;

      await tester.tap(find.text("vllm"));
      await settleIo(tester);
      await tester.enterText(dialogField("Name"), "gpu");
      await tester.pump();
      await saveDialog(tester);

      expect(saved().single.displayName, "gpu");
      expect(saved().single.id, id);
      expect(app.secrets.providerKey(id), "sk-v");
    });
  });

  group("running commands", () {
    Future<void> openModeDropdown(WidgetTester tester) async {
      final field = find.byType(DropdownButtonFormField<ApproveMode>);
      await scrollTo(tester, field);
      await tester.tap(field);
      await settleIo(tester);
    }

    testWidgets("defaults to auto, degraded to asking without a classifier", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.llms);
      await scrollTo(tester, find.text("Running commands"));

      expect(
        app.container.read(appSettingsProvider).approveMode,
        ApproveMode.auto,
      );
      expect(find.textContaining("No classifier model set"), findsOneWidget);
    });

    testWidgets("can be switched to run without asking", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.llms);
      await openModeDropdown(tester);
      await tester.tap(
        find.textContaining("Run everything without asking").last,
      );
      await settleIo(tester);

      expect(
        app.container.read(appSettingsProvider).approveMode,
        ApproveMode.never,
      );
      expect(AppSettings.load(app.config).approveMode, ApproveMode.never);
    });

    testWidgets("auto is disabled when no classifier model is set", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.llms);
      await openModeDropdown(tester);
      await tester.tap(find.textContaining("Ask before every command").last);
      await settleIo(tester);
      await openModeDropdown(tester);

      // The item is there but greyed out — tapping it does nothing.
      final autoItem = find.textContaining(
        "Auto: run what the classifier rates safe",
      );
      expect(autoItem, findsOneWidget);
      await tester.tap(autoItem);
      await settleIo(tester);

      expect(
        app.container.read(appSettingsProvider).approveMode,
        ApproveMode.ask,
      );
    });

    testWidgets("changing the mode does not disturb the providers", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await saveDialog(tester);

      await openCategory(tester, SettingsCategory.llms);
      await openModeDropdown(tester);
      await tester.tap(
        find.textContaining("Run everything without asking").last,
      );
      await settleIo(tester);

      expect(saved().map((p) => p.displayName), ["OpenAI"]);
    });
  });
  group("the default project's permissions", () {
    testWidgets("the rules list renders the tier's rules", (tester) async {
      final settings = ProjectSettings()
        ..permissions = [
          const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.deny,
          ),
          const PermissionRule(
            tool: "read",
            pattern: "/home/x/doc",
            decision: PermissionDecision.allow,
          ),
        ];
      await io(tester, () => settings.save(app.config, project: null));
      app.container.invalidate(projectSettingsProvider(null));
      await pumpSettings(tester, app, SettingsCategory.terminal);
      await scrollTo(tester, find.text("Permissions"));

      expect(find.text("Shell commands (bash): git *"), findsOneWidget);
      expect(find.text("Block it"), findsOneWidget);
      expect(find.text("Reading files (read): /home/x/doc"), findsOneWidget);
      expect(find.text("Run without asking"), findsOneWidget);
    });

    testWidgets("a rule can set the sandbox and leave asking to the mode", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.terminal);
      await scrollTo(tester, find.text("Add rule"));
      await tester.tap(find.text("Add rule"));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, "Command"),
        "podman *",
      );
      await tester.pump();
      await tester.tap(find.text("Run without asking").last);
      await tester.pumpAndSettle();
      await tester.tap(find.text("Default (the approval mode decides)").last);
      await tester.pumpAndSettle();
      // Both questions on Default: the rule would say nothing.
      expect(find.textContaining("would change nothing"), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, "Save"))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text("Default (workspaces only)"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Default (workspaces only)").last);
      await tester.pumpAndSettle();
      await tester.tap(find.text("Anywhere (no sandbox)").last);
      await tester.pumpAndSettle();
      await tester.tap(find.text("Save"));
      await io(tester, () async {});
      await settleIo(tester);
      await scrollTo(tester, find.text("Shell commands (bash): podman *"));

      final rule = ProjectSettings.load(
        app.config,
        project: null,
      ).permissions.single;
      expect(rule.pattern, "podman *");
      expect(rule.decision, isNull);
      expect(rule.unconfined, isTrue);
      expect(find.text("Shell commands (bash): podman *"), findsOneWidget);
      expect(find.text("No sandbox"), findsOneWidget);
    });
  });
}
