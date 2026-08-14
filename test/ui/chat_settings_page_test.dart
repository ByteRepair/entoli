import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/local_chat_store.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";

const _chatId = "chat-1";

void main() {
  late Directory tmp;
  late AppConfig config;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("chat_settings_test_");
    config = AppConfig.forDirectory(tmp);
    Directory(config.chatDir(_chatId).path).createSync(recursive: true);
    container = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(LocalChatStore(config)),
        agentBackendProvider.overrideWithValue(FakeBackend()),
        appConfigProvider.overrideWithValue(config),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void seedMeta(Map<String, dynamic> json) =>
      config.metaFile(_chatId).writeAsStringSync(jsonEncode(json));

  void seedGlobalDefault(String providerId, String modelId) =>
      config.settingsFile.writeAsStringSync(
          jsonEncode({"defaultProviderId": providerId, "defaultModelId": modelId}));

  Map<String, dynamic> savedMeta() =>
      jsonDecode(config.metaFile(_chatId).readAsStringSync()) as Map<String, dynamic>;

  // Pushes the page on a route so the save button's pop() has somewhere to go,
  // and so a second tap re-creates the page the way reopening it does.
  Future<void> openPage(WidgetTester tester) async {
    if (!tester.any(find.text("open"))) {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ChatSettingsPage(chatId: _chatId),
                    ),
                  ),
                  child: const Text("open"),
                ),
              ),
            ),
          ),
        ),
      );
    }
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
  }

  List<String?> popupLabels(WidgetTester tester) => tester
      .widgetList<Text>(find.descendant(
        of: find.byType(ListView).last,
        matching: find.byType(Text),
      ))
      .map((t) => t.data)
      .toList();

  Future<void> openDropdown(WidgetTester tester, {required bool model}) async {
    final dropdowns = find.byType(DropdownButtonFormField<String?>);
    await tester.tap(model ? dropdowns.last : dropdowns.first);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip("Save"));
    await tester.pumpAndSettle();
  }

  testWidgets("preselects the provider and model stored in meta.json", (tester) async {
    seedMeta({"provider": "ollama-cloud", "model": "qwen-2.5"});
    await openPage(tester);

    expect(find.text("ollama-cloud"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("chosen model is still shown after saving and reopening", (tester) async {
    await openPage(tester);

    await openDropdown(tester, model: false);
    await tester.tap(find.text("ollama-cloud"));
    await tester.pumpAndSettle();

    await openDropdown(tester, model: true);
    await tester.tap(find.text("Qwen 2.5"));
    await tester.pumpAndSettle();

    await save(tester);
    expect(savedMeta(), {"provider": "ollama-cloud", "model": "qwen-2.5"});

    await openPage(tester);
    expect(find.text("ollama-cloud"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("picking a model records the provider it belongs to", (tester) async {
    await openPage(tester);

    await openDropdown(tester, model: true);
    await tester.tap(find.text("Claude Sonnet 4"));
    await tester.pumpAndSettle();

    await save(tester);
    expect(savedMeta()["provider"], "anthropic");
    expect(savedMeta()["model"], "claude-sonnet-4");
  });

  testWidgets("switching provider drops a model that is no longer offered", (tester) async {
    seedMeta({"provider": "ollama-cloud", "model": "qwen-2.5"});
    await openPage(tester);

    await openDropdown(tester, model: false);
    await tester.tap(find.text("anthropic"));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text("Qwen 2.5"), findsNothing);

    await save(tester);
    expect(savedMeta()["model"], isNull);
  });

  testWidgets("a model saved without its provider is still preselected", (tester) async {
    seedMeta({"model": "qwen-2.5"});
    await openPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text("ollama-cloud"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("a saved model the backend no longer offers does not break the page", (tester) async {
    seedMeta({"provider": "anthropic", "model": "gone-1"});
    await openPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text("anthropic"), findsOneWidget);
    final modelField = tester.widget<DropdownButtonFormField<String?>>(
      find.byType(DropdownButtonFormField<String?>).last,
    );
    expect(modelField.initialValue, isNull);
  });

  testWidgets("a chat with no override reads Default and names what it inherits", (tester) async {
    seedGlobalDefault("ollama-cloud", "qwen-2.5");
    await openPage(tester);

    // provider, model, temperature readout, reasoning effort
    expect(find.text(defaultOptionLabel), findsNWidgets(4));
    expect(find.text("Using ollama-cloud"), findsOneWidget);
    expect(find.text("Using Qwen 2.5"), findsOneWidget);
  });

  testWidgets("Default leads every option list", (tester) async {
    seedGlobalDefault("ollama-cloud", "qwen-2.5");
    await openPage(tester);

    await openDropdown(tester, model: false);
    expect(popupLabels(tester), [defaultOptionLabel, "anthropic", "ollama-cloud"]);
    await tester.tap(find.text("anthropic").last);
    await tester.pumpAndSettle();

    await openDropdown(tester, model: true);
    expect(popupLabels(tester), [defaultOptionLabel, "Claude Haiku 3", "Claude Sonnet 4"]);
  });

  testWidgets("the reset button clears a pinned model back to Default", (tester) async {
    seedMeta({"provider": "ollama-cloud", "model": "qwen-2.5"});
    await openPage(tester);
    expect(find.text("Qwen 2.5"), findsOneWidget);

    await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").at(1));
    await tester.pumpAndSettle();

    expect(find.text("Qwen 2.5"), findsNothing);
    await save(tester);
    expect(savedMeta()["model"], isNull);
    expect(savedMeta()["provider"], "ollama-cloud");
  });

  testWidgets("selecting Default in the list is the same as resetting", (tester) async {
    seedMeta({"provider": "ollama-cloud", "model": "qwen-2.5"});
    await openPage(tester);

    await openDropdown(tester, model: true);
    await tester.tap(find.text(defaultOptionLabel).last);
    await tester.pumpAndSettle();

    await save(tester);
    expect(savedMeta()["model"], isNull);
  });

  testWidgets("a chat's own model wins over the global default", (tester) async {
    seedGlobalDefault("ollama-cloud", "qwen-2.5");
    seedMeta({"provider": "anthropic", "model": "claude-haiku-3"});
    await openPage(tester);

    expect(find.text("anthropic"), findsOneWidget);
    expect(find.text("Claude Haiku 3"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsNothing);
  });

  testWidgets("temperature and reasoning effort round-trip through meta.json", (tester) async {
    seedMeta({"temperature": 0.4, "reasoningEffort": "high"});
    await openPage(tester);

    expect(find.text("0.40"), findsOneWidget);
    expect(find.text("high"), findsOneWidget);

    await save(tester);
    expect(savedMeta()["temperature"], 0.4);
    expect(savedMeta()["reasoningEffort"], "high");
  });
}
