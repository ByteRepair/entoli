import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../harness.dart";

const _chatId = "chat-1";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  void seedMeta(ChatMeta meta) => app.seedChatMeta(_chatId, meta);

  void seedGlobalDefault(String providerId, String modelId) =>
      app.seedGlobalDefault(providerId: providerId, modelId: modelId);

  // Pushes the page on a route so the save button's pop() has somewhere to go,
  // and so a second tap re-creates the page the way reopening it does.
  Future<void> openPage(WidgetTester tester) async {
    if (!tester.any(find.text("open"))) {
      await app.pump(
        tester,
        Scaffold(
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
      );
    }
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip("Save"));
    await tester.pumpAndSettle();
  }

  testWidgets("preselects the provider and model stored in meta.json", (tester) async {
    seedMeta(ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
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
    expect(app.savedMeta(_chatId).provider, "ollama-cloud");
    expect(app.savedMeta(_chatId).model, "qwen-2.5");

    await openPage(tester);
    expect(find.text("ollama-cloud"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("picking a model records the provider it belongs to", (tester) async {
    await openPage(tester);

    await openDropdown(tester, model: false);
    await tester.tap(find.text("anthropic").last);
    await tester.pumpAndSettle();

    await openDropdown(tester, model: true);
    await tester.tap(find.text("Claude Sonnet 4"));
    await tester.pumpAndSettle();

    await save(tester);
    expect(app.savedMeta(_chatId).provider, "anthropic");
    expect(app.savedMeta(_chatId).model, "claude-sonnet-4");
  });

  testWidgets("switching provider drops a model that is no longer offered", (tester) async {
    seedMeta(ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
    await openPage(tester);

    await openDropdown(tester, model: false);
    await tester.tap(find.text("anthropic"));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text("Qwen 2.5"), findsNothing);

    await save(tester);
    expect(app.savedMeta(_chatId).model, isNull);
  });

  testWidgets("a model saved without its provider is still preselected", (tester) async {
    seedMeta(ChatMeta(model: "qwen-2.5"));
    await openPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text("ollama-cloud"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("a chat with no override reads Default and names what it inherits", (tester) async {
    seedGlobalDefault("ollama-cloud", "qwen-2.5");
    await openPage(tester);

    // provider and model; the approval field names what it inherits instead
    expect(find.text(defaultOptionLabel), findsNWidgets(2));
    expect(find.text("Using ollama-cloud"), findsOneWidget);
    expect(find.text("Using Qwen 2.5"), findsOneWidget);
  });

  testWidgets("the reset button clears a pinned model back to Default", (tester) async {
    seedMeta(ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
    await openPage(tester);
    expect(find.text("Qwen 2.5"), findsOneWidget);

    await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").at(1));
    await tester.pumpAndSettle();

    expect(find.text("Qwen 2.5"), findsNothing);
    await save(tester);
    expect(app.savedMeta(_chatId).model, isNull);
    expect(app.savedMeta(_chatId).provider, "ollama-cloud");
  });

  testWidgets("selecting Default in the list is the same as resetting", (tester) async {
    seedMeta(ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
    await openPage(tester);

    await openDropdown(tester, model: true);
    await tester.tap(find.text(defaultOptionLabel).last);
    await tester.pumpAndSettle();

    await save(tester);
    expect(app.savedMeta(_chatId).model, isNull);
  });

  testWidgets("Default follows the global default as it changes", (tester) async {
    app.seedGlobalDefault(providerId: "ollama-cloud", modelId: "qwen-2.5");
    await openPage(tester);
    expect(find.text("Using Qwen 2.5"), findsOneWidget);

    // Nothing is pinned on the chat, so retargeting the global retargets it.
    app.container
        .read(appSettingsProvider.notifier)
        .setDefault((providerId: "anthropic", modelId: "claude-haiku-3"));
    await tester.pumpAndSettle();

    expect(find.text("Using anthropic"), findsOneWidget);
    expect(find.text("Using Claude Haiku 3"), findsOneWidget);
    expect(app.savedMeta(_chatId).model, isNull);
  });

  testWidgets("a chat's own model wins over the global default", (tester) async {
    seedGlobalDefault("ollama-cloud", "qwen-2.5");
    seedMeta(ChatMeta(provider: "anthropic", model: "claude-haiku-3"));
    await openPage(tester);

    expect(find.text("anthropic"), findsOneWidget);
    expect(find.text("Claude Haiku 3"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsNothing);
  });

  group("running commands", () {
    Future<void> openField(WidgetTester tester) async {
      await openPage(tester);
      await scrollTo(tester, find.byType(DropdownButtonFormField<bool?>));
      await tester.tap(find.byType(DropdownButtonFormField<bool?>));
      await tester.pumpAndSettle();
    }

    testWidgets("Default names what the app would do", (tester) async {
      await openPage(tester);
      await scrollTo(tester, find.text("Running commands"));

      expect(find.text("$defaultOptionLabel (Ask every time)"), findsOneWidget);
      expect(app.savedMeta(_chatId).approveCommands, isNull);
    });

    testWidgets("Default follows the app setting as it changes", (tester) async {
      await app.container.read(appSettingsProvider.notifier).setApproveCommands(false);
      await openPage(tester);
      await scrollTo(tester, find.text("Running commands"));

      expect(find.text("$defaultOptionLabel (Run without asking)"), findsOneWidget);
    });

    testWidgets("a chat can run without asking, and that survives a save", (tester) async {
      await openField(tester);
      await tester.tap(find.text("Run without asking").last);
      await tester.pumpAndSettle();
      await save(tester);

      expect(app.savedMeta(_chatId).approveCommands, isFalse);
    });

    testWidgets("resetting puts it back on the app's answer", (tester) async {
      seedMeta(ChatMeta(approveCommands: false));
      await openPage(tester);
      await scrollTo(tester, find.text("Running commands"));
      expect(find.text("Run without asking"), findsOneWidget);

      await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").last);
      await tester.pumpAndSettle();
      await save(tester);

      expect(app.savedMeta(_chatId).approveCommands, isNull);
    });
  });
}
