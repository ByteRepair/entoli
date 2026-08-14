import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// The wide layout: the sidebar sits beside the chat pane, no drawer.
  Future<void> pumpBeside(WidgetTester tester) =>
      app.pump(tester, const Row(children: [SizedBox(width: 280, child: Sidebar())]));

  /// The narrow layout: the sidebar is a drawer over the chat.
  Future<void> pumpAsDrawer(WidgetTester tester) async {
    await app.pump(
      tester,
      Scaffold(
        drawer: const Drawer(child: Sidebar()),
        body: const SizedBox.shrink(),
        appBar: AppBar(
          leading: Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  testWidgets("the new chat button selects the chat it just created", (tester) async {
    await pumpBeside(tester);
    expect(app.container.read(selectedChatIdProvider), isNull);

    await tester.tap(find.byTooltip("New chat"));
    await tester.pumpAndSettle();

    final chats = await app.repo.listChats();
    expect(chats, hasLength(1));
    expect(app.container.read(selectedChatIdProvider), chats.single.id);
  });

  testWidgets("a second new chat becomes the selected one", (tester) async {
    await pumpBeside(tester);

    await tester.tap(find.byTooltip("New chat"));
    await tester.pumpAndSettle();
    final first = app.container.read(selectedChatIdProvider);

    await tester.tap(find.byTooltip("New chat"));
    await tester.pumpAndSettle();

    expect(app.container.read(selectedChatIdProvider), isNot(first));
  });

  testWidgets("creating a chat from the drawer closes it", (tester) async {
    await pumpAsDrawer(tester);

    await tester.tap(find.byTooltip("New chat"));
    await tester.pumpAndSettle();

    expect(app.container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets("tapping an existing chat in the drawer closes it too", (tester) async {
    await app.repo.createChat(title: "old chat");
    await pumpAsDrawer(tester);

    await tester.tap(find.text("old chat"));
    await tester.pumpAndSettle();

    expect(app.container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets("selecting beside the chat pane leaves the sidebar in place", (tester) async {
    await app.repo.createChat(title: "old chat");
    await pumpBeside(tester);

    await tester.tap(find.text("old chat"));
    await tester.pumpAndSettle();

    expect(app.container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Sidebar), findsOneWidget);
  });
}
