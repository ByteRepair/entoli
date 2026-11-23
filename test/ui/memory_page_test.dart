import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/memory/store.dart";
import "package:entoli_chat/domain/project.dart" show localProject;
import "package:agent_chat/ui/memory/memory_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;
  late MemoryStore store;

  setUp(() {
    app = TestApp.create();
    store = MemoryStore(app.config.memoryDir());
  });
  tearDown(() => app.dispose());

  Future<void> open(WidgetTester tester) async {
    await app.pump(
      tester,
      MemoryPage(project: localProject(null), title: "Memories"),
    );
    await settleIo(tester);
  }

  List<String?> titles(WidgetTester tester) => tester
      .widgetList<ListTile>(find.byType(ListTile))
      .map((t) => (t.title as Text).data)
      .toList();

  testWidgets("the store's memories, newest first, with whose they are", (
    tester,
  ) async {
    await io(tester, () async {
      await store.add("older");
      await store.add("newer", chat: "chat-1");
    });
    await open(tester);
    expect(titles(tester), ["newer", "older"]);
    expect(find.textContaining("kept by the agent"), findsOneWidget);
    expect(find.textContaining("added by you"), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets("an empty store offers to add one, and what is typed lands", (
    tester,
  ) async {
    await open(tester);
    expect(find.text("No memories yet"), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, "Add a memory"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, "  prefers tabs  ");
    await tester.tap(find.text("Save"));
    await pumpUntil(tester, find.text("prefers tabs"));

    expect(titles(tester), ["prefers tabs"]);
    expect((await io(tester, store.entries)).single.text, "prefers tabs");
  });

  testWidgets("the bar adds one too", (tester) async {
    await io(tester, () => store.add("first"));
    await open(tester);
    await tester.tap(find.byTooltip("Add a memory"));
    await tester.pumpAndSettle();
    expect(find.text("New memory"), findsOneWidget);
  });

  testWidgets("a tap shows the whole memory with its date and author", (
    tester,
  ) async {
    await io(tester, () => store.add("a long fact"));
    await open(tester);
    await tester.tap(find.text("a long fact"));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining("added by you"),
      ),
      findsOneWidget,
    );
  });

  testWidgets("deleting asks, then the memory is gone", (tester) async {
    await io(tester, () => store.add("forget me"));
    await open(tester);
    await tester.tap(find.byTooltip("Delete memory"));
    await tester.pumpAndSettle();
    expect(find.text("Delete memory?"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, "Delete"));
    await pumpUntil(tester, find.text("No memories yet"));
    expect(find.text("No memories yet"), findsOneWidget);
    expect(await io(tester, store.entries), isEmpty);
  });

  testWidgets("a pin marks it; past the limit it is refused", (tester) async {
    await io(tester, () async {
      for (var i = 0; i < pinnedLimit; i++) {
        final entry = await store.add("standing $i");
        await store.pin(entry.id);
      }
      await store.add("one more");
    });
    await open(tester);
    expect(find.byIcon(Icons.push_pin), findsNWidgets(pinnedLimit));

    await tester.tap(find.byTooltip("Pin: in every turn"));
    await settleIo(tester);
    expect(find.text("Four is the most that can be pinned."), findsOneWidget);
    final all = await io(tester, store.entries);
    expect(all.where((e) => e.text == "one more").single.pinned, isFalse);

    await tester.tap(find.byTooltip("Unpin").first);
    await settleIo(tester);
    expect(find.byIcon(Icons.push_pin), findsNWidgets(pinnedLimit - 1));
  });

  testWidgets("a search narrows to the memories its words are in", (
    tester,
  ) async {
    await io(tester, () async {
      await store.add("likes rust");
      await store.add("dislikes meetings");
    });
    await open(tester);
    expect(find.byIcon(Icons.search), findsOneWidget);

    await tester.enterText(find.byType(TextField), "rust");
    await settleUntil(tester, () => titles(tester).length == 1);
    expect(titles(tester), ["likes rust"]);

    await tester.enterText(find.byType(TextField), "nothing like it");
    await pumpUntil(tester, find.text("No memories match"));
    expect(find.text("No memories match"), findsOneWidget);
    expect(find.textContaining("nothing like it"), findsWidgets);
    expect(find.widgetWithText(FilledButton, "Add a memory"), findsNothing);
  });
}
