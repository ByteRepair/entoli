import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../harness.dart";

const _chatId = "chat-1";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> seedMeta(WidgetTester tester, ChatMeta meta) =>
      io(tester, () => app.seedChatMeta(_chatId, meta));

  /// Write `state.json` for the fixed chat id, so the page can read `pinned`
  /// and the project off it. `seedChat` would use a generated id; the tests
  /// here are pinned to `_chatId` because the page is constructed with it
  /// directly.
  Future<void> seedState(WidgetTester tester,
          {bool pinned = false, String? project}) =>
      io(tester, () async {
        final chat =
            await app.repo.createChat(title: "chat", project: project);
        await app.repo.saveState(
            chat.state.copyWith(id: _chatId, pinned: pinned));
      });

  Future<void> seedGlobalDefault(WidgetTester tester, String providerId, String modelId) =>
      io(tester, () => app.seedGlobalDefault(providerId: providerId, modelId: modelId));

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
    await settleIo(tester);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip("Save"));
    await settleIo(tester);
  }

  testWidgets("preselects the model stored in meta.json", (tester) async {
    await seedMeta(tester, ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
    await openPage(tester);

    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("chosen model is still shown after saving and reopening", (tester) async {
    await openPage(tester);

    await openPickerFor(tester);
    await tester.dragUntilVisible(
        find.text("Qwen 2.5"), find.byType(CustomScrollView), const Offset(0, -200));
    await tester.tap(find.text("Qwen 2.5").last);
    await settleIo(tester);

    await save(tester);
    expect((await io(tester, () => app.savedMeta(_chatId))).provider, "ollama-cloud");
    expect((await io(tester, () => app.savedMeta(_chatId))).model, "qwen-2.5");

    await openPage(tester);
    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("a model saved without its provider is still preselected", (tester) async {
    await seedMeta(tester, ChatMeta(model: "qwen-2.5"));
    await openPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("Default follows the global default as it changes", (tester) async {
    app.seedGlobalDefault(providerId: "ollama-cloud", modelId: "qwen-2.5");
    await openPage(tester);
    // With no override the picker reads Default's entry, and names what it
    // inherits instead of the app's own pick.
    expect(find.text(defaultOptionLabel), findsOneWidget);
    expect(find.text("Using Qwen 2.5"), findsOneWidget);

    // Nothing is pinned on the chat, so retargeting the global retargets it.
    app.container
        .read(appSettingsProvider.notifier)
        .setDefault((providerId: "anthropic", modelId: "claude-haiku-3"));
    await settleIo(tester);

    expect(find.text("Using Claude Haiku 3"), findsOneWidget);
    expect((await io(tester, () => app.savedMeta(_chatId))).model, isNull);
  });

  testWidgets("the reset button clears a pinned model back to Default", (tester) async {
    await seedMeta(tester, ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
    await openPage(tester);
    expect(find.text("Qwen 2.5"), findsOneWidget);

    await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").first);
    await settleIo(tester);

    expect(find.text("Qwen 2.5"), findsNothing);
    await save(tester);
    expect((await io(tester, () => app.savedMeta(_chatId))).model, isNull);
    expect((await io(tester, () => app.savedMeta(_chatId))).provider, isNull);
  });

  testWidgets("selecting Default in the list is the same as resetting", (tester) async {
    await seedMeta(tester, ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
    await openPage(tester);

    await openPickerFor(tester);
    await tester.tap(find.textContaining(defaultOptionLabel).last);
    await settleIo(tester);

    await save(tester);
    expect((await io(tester, () => app.savedMeta(_chatId))).model, isNull);
  });

  testWidgets("a chat's own model wins over the global default", (tester) async {
    await seedGlobalDefault(tester, "ollama-cloud", "qwen-2.5");
    await seedMeta(tester, ChatMeta(provider: "anthropic", model: "claude-haiku-3"));
    await openPage(tester);

    expect(find.text("Claude Haiku 3"), findsOneWidget);
    expect(find.text("Qwen 2.5"), findsNothing);
  });

  group("running commands", () {
    Future<void> openField(WidgetTester tester) async {
      await openPage(tester);
      await scrollTo(tester, find.byType(DropdownButtonFormField<ApproveMode?>));
      await tester.tap(find.byType(DropdownButtonFormField<ApproveMode?>));
      await settleIo(tester);
    }

    testWidgets("Default names what the app would do", (tester) async {
      await openPage(tester);
      await scrollTo(tester, find.text("Running commands"));

      expect(
          find.text(
              "$defaultOptionLabel (Auto: run what the classifier rates safe, ask on the rest)"),
          findsOneWidget);
      expect((await io(tester, () => app.savedMeta(_chatId))).approveMode, isNull);

      // And it follows the app setting as it changes: the app's mode is the
      // label's parameter.
      await save(tester);
      await io(tester, () => app.container
          .read(appSettingsProvider.notifier).setApproveMode(ApproveMode.never));
      await openPage(tester);
      await scrollTo(tester, find.text("Running commands"));

      expect(find.text("$defaultOptionLabel (Run everything without asking (DANGEROUS))"), findsOneWidget);
    });

    testWidgets("a chat can run without asking, and that survives a save", (tester) async {
      await openField(tester);
      await tester.tap(find.textContaining("Run everything without asking").last);
      await settleIo(tester);
      await save(tester);

      expect((await io(tester, () => app.savedMeta(_chatId))).approveMode, ApproveMode.never);
    });

    testWidgets("resetting puts it back on the app's answer", (tester) async {
      await seedMeta(tester, ChatMeta(approveMode: ApproveMode.never));
      await openPage(tester);
      await scrollTo(tester, find.text("Running commands"));
      expect(find.textContaining("Run everything without asking"), findsOneWidget);

      await tester.tap(find.byTooltip("Reset to $defaultOptionLabel").at(1));
      await settleIo(tester);
      await save(tester);

      expect((await io(tester, () => app.savedMeta(_chatId))).approveMode, isNull);
    });
  });

  group("project memory", () {
    final toggle = find.widgetWithText(SwitchListTile, "Project memory");

    Future<void> openRow(WidgetTester tester) async {
      await openPage(tester);
      await scrollTo(tester, find.text("Project memory"));
    }

    testWidgets("a chat follows the project until it keeps out", (tester) async {
      await openRow(tester);

      expect(tester.widget<SwitchListTile>(toggle).value,
          isTrue);
      expect((await io(tester, () => app.savedMeta(_chatId))).memoryOff, isNull);
    });

    testWidgets("keeping out stores the off, and it survives a save",
        (tester) async {
      await openRow(tester);
      await tester.tap(toggle);
      await settleIo(tester);
      await save(tester);

      expect((await io(tester, () => app.savedMeta(_chatId))).memoryOff, isTrue);
    });

    testWidgets("turning it back on returns the chat to the project",
        (tester) async {
      await seedMeta(tester, ChatMeta(memoryOff: true));
      await openRow(tester);

      expect(tester.widget<SwitchListTile>(toggle).value,
          isFalse);

      await tester.tap(toggle);
      await settleIo(tester);
      await save(tester);

      expect((await io(tester, () => app.savedMeta(_chatId))).memoryOff, isNull);
    });

    testWidgets("a project that keeps no memories says so and takes nothing",
        (tester) async {
      await seedState(tester, project: "anonymous");
      await openRow(tester);

      final tile = tester.widget<SwitchListTile>(toggle);
      expect(find.text("This project keeps no memories."), findsOneWidget);
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNull);
    });
  });

  group("sandbox", () {
    final toggle = find.descendant(
        of: find.byType(InheritableSwitch),
        matching: find.byType(SwitchListTile));

    testWidgets("a chat can turn it off for itself, and that survives a save",
        (tester) async {
      await openPage(tester);
      await scrollTo(tester, toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect((await io(tester, () => app.savedMeta(_chatId))).sandbox, isNull);

      await tester.tap(toggle);
      await settleIo(tester);
      await save(tester);

      expect((await io(tester, () => app.savedMeta(_chatId))).sandbox, isFalse);
    });
  });

  group("temporary chat, when pinned", () {
    Future<void> scrollToTemporary(WidgetTester tester) =>
        scrollTo(tester, find.text("Temporary chat"));

    testWidgets("a pinned chat says so in place of the TTL combobox", (tester) async {
      await seedState(tester, pinned: true);
      await openPage(tester);
      await scrollToTemporary(tester);

      expect(find.text("This chat is pinned and cannot be temporary."), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<TempChatTtl?>), findsNothing);
    });

    testWidgets("an unpinned chat shows the TTL combobox", (tester) async {
      await seedState(tester, pinned: false);
      await openPage(tester);
      await scrollToTemporary(tester);

      expect(find.byType(DropdownButtonFormField<TempChatTtl?>), findsOneWidget);
      expect(find.text("This chat is pinned and cannot be temporary."), findsNothing);
    });
  });
}
