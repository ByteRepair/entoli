import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:entoli_chat/domain/chat_meta.dart";
import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/chat/context_page.dart";
import "package:entoli_chat/ui/workspace/workspace_page.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// Opened over a host page, as the chat's title bar opens it, so leaving
  /// it has somewhere to go.
  Future<void> host(
    WidgetTester tester,
    void Function(BuildContext) open,
  ) async {
    useWindow(tester, const Size(800, 2000));
    await app.pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text("host"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("host"));
    await settleIo(tester);
  }

  Future<void> open(WidgetTester tester, String id) =>
      host(tester, (context) => openChatSettings(context, id));

  Future<String> seed(
    WidgetTester tester, {
    bool pinned = false,
    String? project,
  }) => io(tester, () async {
    final chat = await app.repo.createChat(title: "chat", project: project);
    if (pinned) await app.repo.saveState(chat.state.copyWith(pinned: true));
    return chat.state.id;
  });

  Future<void> save(WidgetTester tester) async {
    await tester.tap(buttonTipped("Save"));
    await settleIo(tester);
  }

  Future<ChatMeta> saved(WidgetTester tester, String id) =>
      io(tester, () => app.savedMeta(id));

  testWidgets("keeping out of memory stores the off, and on stores nothing", (
    tester,
  ) async {
    final id = await seed(tester);
    await open(tester, id);
    await tester.tap(find.text("Project memory"));
    await tester.pump();
    await save(tester);
    expect((await saved(tester, id)).memoryOff, isTrue);
    expect(find.text("host"), findsOneWidget);

    await tester.tap(find.text("host"));
    await settleIo(tester);
    await tester.tap(find.text("Project memory"));
    await tester.pump();
    await save(tester);
    expect((await saved(tester, id)).memoryOff, isNull);
  });

  testWidgets("a project that keeps no memories says so and takes nothing", (
    tester,
  ) async {
    await open(tester, await seed(tester, project: "anonymous"));
    expect(find.text("This project keeps no memories."), findsOneWidget);
    final memory = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, "Project memory"),
    );
    expect(memory.value, isFalse);
    expect(memory.onChanged, isNull);
  });

  testWidgets("a chat can turn the sandbox off for itself, and only that", (
    tester,
  ) async {
    final id = await seed(tester);
    await open(tester, id);
    expect(find.text("Sandbox — Default (on)"), findsOneWidget);
    // The folders granted beside the workspaces are a project's to set.
    expect(find.text("System temp folders"), findsNothing);

    await tester.tap(find.widgetWithText(SwitchListTile, "Sandbox"));
    await tester.pump();
    expect(
      find.text("Off: this chat's commands write wherever you can."),
      findsOneWidget,
    );
    await save(tester);
    expect((await saved(tester, id)).sandbox, isFalse);
  });

  testWidgets("running commands is the LLMs page's, at the chat's level", (
    tester,
  ) async {
    await open(tester, await seed(tester));
    expect(find.text("Running commands"), findsOneWidget);
    expect(find.textContaining("Default ("), findsWidgets);
  });

  testWidgets("a pinned chat says so in place of how long it lives", (
    tester,
  ) async {
    await open(tester, await seed(tester, pinned: true));
    expect(
      find.text("This chat is pinned and cannot be temporary."),
      findsOneWidget,
    );
    expect(find.text("Delete after"), findsNothing);
  });

  testWidgets("an unpinned chat picks how long it lives", (tester) async {
    await open(tester, await seed(tester));
    expect(find.text("Delete after"), findsOneWidget);
    expect(
      find.text("This chat is pinned and cannot be temporary."),
      findsNothing,
    );
  });

  testWidgets("leaving with a change asks first, and without one does not", (
    tester,
  ) async {
    final id = await seed(tester);
    await open(tester, id);
    await tester.pageBack();
    await settleIo(tester);
    expect(find.text("host"), findsOneWidget);

    await tester.tap(find.text("host"));
    await settleIo(tester);
    await tester.tap(find.text("Project memory"));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text("Discard"), findsOneWidget);
    await tester.tap(find.text("Discard"));
    await settleIo(tester);
    expect(find.text("host"), findsOneWidget);
    expect((await saved(tester, id)).memoryOff, isNull);
  });

  testWidgets("the context and the workspace open from their rows", (
    tester,
  ) async {
    await open(tester, await seed(tester));
    await tester.tap(find.text("Context"));
    await settleIo(tester);
    expect(find.byType(ContextPage), findsOneWidget);
    await tester.pageBack();
    await settleIo(tester);

    await tester.tap(find.text("Chat workspace"));
    await settleIo(tester);
    expect(find.byType(WorkspacePage), findsOneWidget);
  });

  testWidgets("Delete takes the chat away, with no state.json to read", (
    tester,
  ) async {
    final id = await seed(tester);
    File(app.config.stateFile(id)).deleteSync();
    await open(tester, id);

    await tester.tap(find.text("Delete Chat"));
    await tester.pumpAndSettle();
    expect(find.text("Delete chat?"), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text("Delete"),
      ),
    );
    await settleIo(tester);

    expect(find.byType(ChatSettingsPage), findsNothing);
    expect(find.text("host"), findsOneWidget);
    expect(Directory(app.config.chatDir(id)).existsSync(), isFalse);
  });

  testWidgets("a save that fails says so and leaves Save to try again", (
    tester,
  ) async {
    final store = FakeChatStore();
    app.dispose();
    app = TestApp.create(store: store);
    final id = await seed(tester);
    await open(tester, id);
    await tester.tap(find.text("Project memory"));
    await tester.pump();

    store.failSaveMeta = StateError("the disk is full");
    await save(tester);
    expect(find.textContaining("That did not work"), findsOneWidget);
    expect(find.byType(ChatSettingsPage), findsOneWidget);
    expect(enabled(tester, buttonTipped("Save")), isTrue);

    await save(tester);
    expect(find.byType(ChatSettingsPage), findsNothing);
    expect((await saved(tester, id)).memoryOff, isTrue);
  });

  testWidgets("a new chat's settings hand back the draft on Save", (
    tester,
  ) async {
    final initial = ChatMeta();
    ChatMeta? kept;
    await host(
      tester,
      (context) => openNewChatSettings(
        context,
        initial: initial,
        project: null,
        onSave: (meta) => kept = meta,
      ),
    );
    // What a chat on disk has and this one does not.
    expect(find.text("Chat ID"), findsNothing);
    expect(find.text("Delete Chat"), findsNothing);

    await tester.tap(find.widgetWithText(SwitchListTile, "Sandbox"));
    await tester.pump();
    await save(tester);

    expect(kept?.sandbox, isFalse);
    expect(initial.sandbox, isNull);
    expect(find.byType(NewChatSettingsPage), findsNothing);
  });
}
