import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/context_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  final at = DateTime.utc(2026, 1, 1);

  Message reply(String id, ContextUsage context, {String? author}) => Message(
      id: id,
      role: MessageRole.assistant,
      createdAt: at,
      author: author,
      context: context);

  Future<String> seed(WidgetTester tester, List<Message> messages) async {
    late String id;
    await io(tester, () async {
      final chat = await app.seedChat();
      id = chat.state.id;
      await app.writeChat(chat.copyWith(messages: messages));
    });
    return id;
  }

  testWidgets("a chat with nothing measured says so", (tester) async {
    final id = await seed(tester, []);
    await app.pump(tester, ContextPage(chatId: id));
    await settleIo(tester);

    expect(find.text("Nothing measured yet"), findsOneWidget);
  });

  testWidgets("one bar per participant, the house first", (tester) async {
    final id = await seed(tester, [
      reply("a1", const ContextUsage(system: 4000, tools: 6000, profile: 200, chat: 20000)),
      reply("a2", const ContextUsage(system: 1000, tools: 2000, profile: 100, chat: 500),
          author: "@reviewer"),
    ]);
    await app.pump(tester, ContextPage(chatId: id));
    await settleIo(tester);

    final house = tester.getTopLeft(find.text("Entoli Agent"));
    final member = tester.getTopLeft(find.text("@reviewer"));
    expect(house.dy, lessThan(member.dy));
    expect(find.text("Auto-compact 80%"), findsNWidgets(2));
    expect(tester.getSize(find.byTooltip("Chat: 20k tokens")).height,
        greaterThan(0));
  });

  testWidgets("a context past the window fills the bar without overflowing",
      (tester) async {
    final id = await seed(tester, [
      reply("a1", const ContextUsage(system: 4000, tools: 6000, profile: 0, chat: 500000)),
    ]);
    await app.pump(tester, ContextPage(chatId: id));
    await settleIo(tester);

    expect(tester.takeException(), isNull);
  });
}
