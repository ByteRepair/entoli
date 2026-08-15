import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> open(WidgetTester tester, String chatId) async {
    app.container.read(selectedChatIdProvider.notifier).select(chatId);
    await app.pump(tester, const ChatPage(), settle: false);
    await pumpUntil(tester, find.byType(Composer));
  }

  testWidgets("a chat in a project says which one above the conversation",
      (tester) async {
    final chat = await app.seedChat(title: "at work", project: "work");

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("work")),
        findsOneWidget);
  });

  // Every chat is in one, so naming the default on all of them says nothing.
  testWidgets("a chat in the default project is titled and nothing more",
      (tester) async {
    final chat = await app.seedChat(title: "at home");

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.byType(Text)),
        findsOneWidget);
    expect(find.text("Default"), findsNothing);
  });
}
