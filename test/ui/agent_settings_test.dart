import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";

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

  Future<void> saveDialog(WidgetTester tester) async {
    await tester.tap(find.text("Save"));
    await settleIo(tester);
  }

  /// A field of the open dialog by its label. Indexed finds would be wrong
  /// whenever something with a TextField sits behind the dialog — the
  /// recommended-provider card's key box does.
  Finder dialogField(String label) => find.widgetWithText(TextField, label);

  List<LlmProviderConfig> saved() => app.container.read(appSettingsProvider).llmProviders;

  group("providers", () {
    testWidgets("says plainly that nothing is configured yet", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);

      expect(find.textContaining("cannot answer until one is added"), findsOneWidget);
    });

    testWidgets("a preset arrives filled in, so only the key is left to type", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Ollama Cloud");

      expect(find.text("ollama-cloud"), findsOneWidget);
      expect(find.text("https://ollama.com/v1"), findsOneWidget);

      await tester.enterText(dialogField("API key"), "sk-ollama");
      await saveDialog(tester);

      expect(saved().single.id, "ollama-cloud");
      expect(saved().single.baseUrl, "https://ollama.com/v1");
      // The key went to the store; no config carries one.
      expect(app.secrets.providerKey("ollama-cloud"), "sk-ollama");
    });

    testWidgets("a custom endpoint starts empty and is typed in", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Custom…");

      await tester.enterText(dialogField("Name"), "vllm");
      await tester.enterText(dialogField("Base URL"), "http://gpu.local:8000/v1");
      await tester.enterText(dialogField("Models"), "qwen3, llama4");
      await saveDialog(tester);

      expect(saved().single.id, "vllm");
      expect(saved().single.baseUrl, "http://gpu.local:8000/v1");
      expect(saved().single.models, ["qwen3", "llama4"]);
      expect(saved().single.api, LlmApi.openai);
    });

    testWidgets("one missing its name or URL is not saved", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Custom…");

      await tester.enterText(dialogField("Name"), "nameless");
      await saveDialog(tester);

      expect(saved(), isEmpty);
    });

    testWidgets("the key is never shown back on the page", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Anthropic");
      await tester.enterText(dialogField("API key"), "sk-ant-secret");
      await saveDialog(tester);

      expect(find.text("sk-ant-secret"), findsNothing);
      // The row says a key is stored, never which.
      expect(find.textContaining("key stored"), findsOneWidget);
    });

    testWidgets("one with no key of its own says which variable it reads", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Anthropic");
      await saveDialog(tester);

      expect(find.textContaining(r"$ANTHROPIC_API_KEY"), findsOneWidget);
    });

    testWidgets("a preset already configured is not offered twice", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Groq");
      await saveDialog(tester);

      await scrollTo(tester, find.text("Add provider"));
      await tester.tap(find.text("Add provider"));
      await settleIo(tester);

      expect(find.text("Groq"), findsOneWidget); // the row, not a picker entry
      expect(find.text("OpenAI"), findsOneWidget);
    });

    testWidgets("a free tier paid for in privacy is accepted before its key is asked", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Google Gemini");

      expect(find.textContaining("free tier is not private"), findsOneWidget);
      await tester.tap(find.text("Cancel").last);
      await settleIo(tester);
      expect(dialogField("API key"), findsNothing);

      await tester.tap(find.text("Google Gemini").last);
      await settleIo(tester);
      await tester.tap(find.text("I understand, add it"));
      await settleIo(tester);
      await tester.enterText(dialogField("API key"), "gm-secret");
      await saveDialog(tester);

      expect(saved().single.id, "google");
    });

    testWidgets("a provider with no free tier is not warned about", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Anthropic");

      expect(find.textContaining("free tier is not private"), findsNothing);
      expect(dialogField("API key"), findsOneWidget);
    });

    testWidgets("editing one replaces it rather than adding another", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await saveDialog(tester);

      await tester.tap(find.text("OpenAI"));
      await settleIo(tester);
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

      await scrollTo(tester, find.byTooltip("Remove groq"));
      await tester.tap(find.byTooltip("Remove groq"));
      await settleIo(tester);

      expect(saved().map((p) => p.id), ["openai"]);
    });

    testWidgets("adding one refreshes what the model picker can offer", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      final before = app.container.read(availableModelsProvider);
      await addProvider(tester, "Anthropic");
      await saveDialog(tester);

      // Invalidated rather than left showing a list built before the provider
      // existed.
      expect(identical(before, app.container.read(availableModelsProvider)), isFalse);
    });

    testWidgets("removing one takes its stored key with it", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await tester.enterText(dialogField("API key"), "sk-o");
      await saveDialog(tester);
      expect(app.secrets.providerKey("openai"), "sk-o");

      await scrollTo(tester, find.byTooltip("Remove openai"));
      await tester.tap(find.byTooltip("Remove openai"));
      await settleIo(tester);

      expect(app.secrets.providerKey("openai"), isNull);
    });

    testWidgets("editing one with a stored key, saving empty, keeps the key",
        (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await tester.enterText(dialogField("API key"), "sk-o");
      await saveDialog(tester);

      await tester.tap(find.text("OpenAI"));
      await settleIo(tester);
      await saveDialog(tester);

      expect(app.secrets.providerKey("openai"), "sk-o");
    });

    testWidgets("renaming one moves the stored key with it", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "Custom…");
      await tester.enterText(dialogField("Name"), "vllm");
      await tester.enterText(dialogField("Base URL"), "http://gpu.local:8000/v1");
      await tester.enterText(dialogField("API key"), "sk-v");
      await saveDialog(tester);
      expect(app.secrets.providerKey("vllm"), "sk-v");

      await tester.tap(find.text("vllm"));
      await settleIo(tester);
      await tester.enterText(dialogField("Name"), "gpu");
      await saveDialog(tester);
      await settleIo(tester);

      expect(saved().map((p) => p.id), ["gpu"]);
      expect(app.secrets.providerKey("gpu"), "sk-v");
      expect(app.secrets.providerKey("vllm"), isNull);
    });
  });

  group("running commands", () {
    Future<void> openModeDropdown(WidgetTester tester) async {
      final field = find.byType(DropdownButtonFormField<ApproveMode>);
      await scrollTo(tester, field);
      await tester.tap(field);
      await settleIo(tester);
    }

    testWidgets("defaults to auto, degraded to asking without a classifier",
        (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await scrollTo(tester, find.text("Running commands"));

      expect(app.container.read(appSettingsProvider).approveMode,
          ApproveMode.auto);
      expect(find.textContaining("No classifier model set"), findsOneWidget);
    });

    testWidgets("can be switched to run without asking", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await openModeDropdown(tester);
      await tester.tap(find.textContaining("Run everything without asking").last);
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).approveMode, ApproveMode.never);
      expect(AppSettings.load(app.config).approveMode, ApproveMode.never);
    });

    testWidgets("auto is disabled when no classifier model is set", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await openModeDropdown(tester);
      await tester.tap(find.textContaining("Ask before every command").last);
      await settleIo(tester);
      await openModeDropdown(tester);

      // The item is there but greyed out — tapping it does nothing.
      final autoItem = find.textContaining("Auto: run what the classifier rates safe");
      expect(autoItem, findsOneWidget);
      await tester.tap(autoItem);
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).approveMode, ApproveMode.ask);
    });

    testWidgets("changing the mode does not disturb the providers", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addProvider(tester, "OpenAI");
      await saveDialog(tester);

      await openCategory(tester, SettingsCategory.general);
      await openModeDropdown(tester);
      await tester.tap(find.textContaining("Run everything without asking").last);
      await settleIo(tester);

      expect(saved().map((p) => p.id), ["openai"]);
    });
  });
  group("the default project's permissions", () {
    testWidgets("the rules list renders the tier's rules", (tester) async {
      final settings = ProjectSettings()
        ..permissions = [
          const PermissionRule(
              tool: "bash", pattern: "git *", decision: PermissionDecision.deny),
          const PermissionRule(
              tool: "read",
              pattern: "/home/x/doc",
              decision: PermissionDecision.allow),
        ];
      await io(tester, () => settings.save(app.config, project: null));
      app.container.invalidate(projectSettingsProvider(null));
      await pumpSettings(tester, app, SettingsCategory.general);
      await scrollTo(tester, find.text("Permissions"));

      expect(find.text("Shell commands (bash): git *"), findsOneWidget);
      expect(find.text("Blocked"), findsOneWidget);
      expect(find.text("Reading files (read): /home/x/doc"), findsOneWidget);
      expect(find.text("Runs without asking"), findsOneWidget);
    });

    testWidgets("the sandbox re-prompt switch reads and writes the tier",
        (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await scrollTo(tester, find.text("Permissions"));

      final row = find.text("Offer to rerun sandbox-denied commands");
      expect(row, findsOneWidget);
      expect(
          tester.widget<SwitchListTile>(find.ancestor(
              of: row, matching: find.byType(SwitchListTile))).value,
          isTrue,
          reason: "the default project's answer is null, which inherits on");

      await tester.tap(row);
      await io(tester, () async {});
      await settleIo(tester);
      expect(
          ProjectSettings.load(app.config, project: null).sandboxReprompt,
          isFalse,
          reason: "the switch writes the default project's own answer");
    });

    testWidgets("a rule can set the sandbox and leave asking to the mode",
        (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await scrollTo(tester, find.text("Add rule"));
      await tester.tap(find.text("Add rule"));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, "Command"), "podman *");
      await tester.pump();
      await tester.tap(find.text("Run without asking").last);
      await tester.pumpAndSettle();
      await tester.tap(find.text("Default (the approval mode decides)").last);
      await tester.pumpAndSettle();
      // Both questions on Default: the rule would say nothing.
      expect(find.textContaining("would change nothing"), findsOneWidget);
      expect(
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, "Save"))
              .onPressed,
          isNull);
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

      final rule = ProjectSettings.load(app.config, project: null)
          .permissions
          .single;
      expect(rule.pattern, "podman *");
      expect(rule.decision, isNull);
      expect(rule.unconfined, isTrue);
      expect(find.text("Shell commands (bash): podman *"), findsOneWidget);
      expect(find.text("No sandbox"), findsOneWidget);
    });
  });

}
