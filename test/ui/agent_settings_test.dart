import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pumpSettings(WidgetTester tester) => app.pump(tester, const SettingsPage());

  /// Open the menu behind the Add provider button and choose an entry.
  Future<void> addProvider(WidgetTester tester, String entry) async {
    await scrollTo(tester, find.text("Add provider"));
    await tester.tap(find.text("Add provider"));
    await tester.pumpAndSettle();
    await tester.tap(find.text(entry).last);
    await tester.pumpAndSettle();
  }

  Future<void> saveDialog(WidgetTester tester) async {
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
  }

  List<LlmProviderConfig> saved() => app.container.read(appSettingsProvider).llmProviders;

  group("providers", () {
    testWidgets("says plainly that nothing is configured yet", (tester) async {
      await pumpSettings(tester);
      await scrollTo(tester, find.text("Providers"));

      expect(find.textContaining("cannot answer until one is added"), findsOneWidget);
    });

    testWidgets("a preset arrives filled in, so only the key is left to type", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "Ollama Cloud");

      expect(find.text("ollama-cloud"), findsOneWidget);
      expect(find.text("https://ollama.com/v1"), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(2), "sk-ollama");
      await saveDialog(tester);

      expect(saved().single.id, "ollama-cloud");
      expect(saved().single.baseUrl, "https://ollama.com/v1");
      expect(saved().single.apiKey, "sk-ollama");
      expect(AppSettings.load(app.config).llmProviders.single.apiKey, "sk-ollama");
    });

    testWidgets("a custom endpoint starts empty and is typed in", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "Custom…");

      await tester.enterText(find.byType(TextField).at(0), "vllm");
      await tester.enterText(find.byType(TextField).at(1), "http://gpu.local:8000/v1");
      await tester.enterText(find.byType(TextField).at(3), "qwen3, llama4");
      await saveDialog(tester);

      expect(saved().single.id, "vllm");
      expect(saved().single.baseUrl, "http://gpu.local:8000/v1");
      expect(saved().single.models, ["qwen3", "llama4"]);
      expect(saved().single.api, LlmApi.openai);
    });

    testWidgets("one missing its name or URL is not saved", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "Custom…");

      await tester.enterText(find.byType(TextField).at(0), "nameless");
      await saveDialog(tester);

      expect(saved(), isEmpty);
    });

    testWidgets("the key is never shown back on the page", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "Anthropic");
      await tester.enterText(find.byType(TextField).at(2), "sk-ant-secret");
      await saveDialog(tester);

      expect(find.text("sk-ant-secret"), findsNothing);
      expect(find.textContaining("key set"), findsOneWidget);
    });

    testWidgets("one with no key of its own says which variable it reads", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "Anthropic");
      await saveDialog(tester);

      expect(find.textContaining(r"$ANTHROPIC_API_KEY"), findsOneWidget);
    });

    testWidgets("a preset already configured is not offered twice", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "Groq");
      await saveDialog(tester);

      await scrollTo(tester, find.text("Add provider"));
      await tester.tap(find.text("Add provider"));
      await tester.pumpAndSettle();

      expect(find.text("Groq"), findsOneWidget); // the row, not a menu entry
      expect(find.text("OpenAI"), findsOneWidget);
    });

    testWidgets("editing one replaces it rather than adding another", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "OpenAI");
      await saveDialog(tester);

      await tester.tap(find.text("OpenAI"));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), "https://proxy.local/v1");
      await saveDialog(tester);

      expect(saved(), hasLength(1));
      expect(saved().single.baseUrl, "https://proxy.local/v1");
    });

    testWidgets("removing one leaves the rest", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "OpenAI");
      await saveDialog(tester);
      await addProvider(tester, "Groq");
      await saveDialog(tester);

      await scrollTo(tester, find.byTooltip("Remove groq"));
      await tester.tap(find.byTooltip("Remove groq"));
      await tester.pumpAndSettle();

      expect(saved().map((p) => p.id), ["openai"]);
    });

    testWidgets("adding one refreshes what the model picker can offer", (tester) async {
      await pumpSettings(tester);
      final before = app.container.read(availableModelsProvider);
      await addProvider(tester, "Anthropic");
      await saveDialog(tester);

      // Invalidated rather than left showing a list built before the provider
      // existed.
      expect(identical(before, app.container.read(availableModelsProvider)), isFalse);
    });
  });

  group("asking before running", () {
    testWidgets("is on until it is turned off", (tester) async {
      await pumpSettings(tester);
      await scrollTo(tester, find.text("Ask before running commands"));

      expect(app.container.read(appSettingsProvider).approveCommands, isTrue);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(app.container.read(appSettingsProvider).approveCommands, isFalse);
      expect(AppSettings.load(app.config).approveCommands, isFalse);
    });

    testWidgets("turning it off does not disturb the providers", (tester) async {
      await pumpSettings(tester);
      await addProvider(tester, "OpenAI");
      await saveDialog(tester);

      await scrollTo(tester, find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(saved().map((p) => p.id), ["openai"]);
    });
  });
}
