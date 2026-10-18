import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/chat/context_page.dart";

import "../harness.dart";

const _chatId = "chat-1";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  testWidgets("nothing measured says so", (tester) async {
    await app.pump(tester, const ContextPage(chatId: _chatId));

    expect(find.text("Nothing measured yet"), findsOneWidget);
  });

  testWidgets("one bar per participant, the house first", (tester) async {
    app.backend.contextHolder[_chatId] = {
      "reviewer": (system: 1000, tools: 2000, profile: 100, chat: 500),
      null: (system: 4000, tools: 6000, profile: 200, chat: 20000),
    };
    await app.pump(tester, const ContextPage(chatId: _chatId));

    final house = tester.getTopLeft(find.text("Entoli Agent"));
    final member = tester.getTopLeft(find.text("@reviewer"));
    expect(house.dy, lessThan(member.dy));
    expect(find.text("Auto-compact 80%"), findsNWidgets(2));
    expect(tester.getSize(find.byTooltip("Chat: 20k tokens")).height,
        greaterThan(0));
  });

  testWidgets("a context past the window fills the bar without overflowing",
      (tester) async {
    app.backend.contextHolder[_chatId] = {
      null: (system: 4000, tools: 6000, profile: 0, chat: 500000),
    };
    await app.pump(tester, const ContextPage(chatId: _chatId));

    expect(tester.takeException(), isNull);
  });
}
