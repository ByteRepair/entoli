import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/local_chat_store.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../fakes.dart";

void main() {
  late Directory tmp;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("sidebar_test_");
    final config = AppConfig.forDirectory(tmp);
    Directory(config.chatsDir.path).createSync(recursive: true);
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

  /// The wide layout: the sidebar sits beside the chat pane, no drawer.
  Future<void> pumpBeside(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Row(children: [SizedBox(width: 280, child: Sidebar())])),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The narrow layout: the sidebar is a drawer over the chat.
  Future<void> pumpAsDrawer(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
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
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  testWidgets("the new chat button selects the chat it just created", (tester) async {
    await pumpBeside(tester);
    expect(container.read(selectedChatIdProvider), isNull);

    await tester.tap(find.byTooltip("New chat"));
    await tester.pumpAndSettle();

    final chats = await container.read(chatRepositoryProvider).listChats();
    expect(chats, hasLength(1));
    expect(container.read(selectedChatIdProvider), chats.single.id);
  });

  testWidgets("a second new chat becomes the selected one", (tester) async {
    await pumpBeside(tester);

    await tester.tap(find.byTooltip("New chat"));
    await tester.pumpAndSettle();
    final first = container.read(selectedChatIdProvider);

    await tester.tap(find.byTooltip("New chat"));
    await tester.pumpAndSettle();

    expect(container.read(selectedChatIdProvider), isNot(first));
  });

  testWidgets("creating a chat from the drawer closes it", (tester) async {
    await pumpAsDrawer(tester);

    await tester.tap(find.byTooltip("New chat"));
    await tester.pumpAndSettle();

    expect(container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets("tapping an existing chat in the drawer closes it too", (tester) async {
    await container.read(chatRepositoryProvider).createChat(title: "old chat");
    await pumpAsDrawer(tester);

    await tester.tap(find.text("old chat"));
    await tester.pumpAndSettle();

    expect(container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets("selecting beside the chat pane leaves the sidebar in place", (tester) async {
    await container.read(chatRepositoryProvider).createChat(title: "old chat");
    await pumpBeside(tester);

    await tester.tap(find.text("old chat"));
    await tester.pumpAndSettle();

    expect(container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Sidebar), findsOneWidget);
  });
}
