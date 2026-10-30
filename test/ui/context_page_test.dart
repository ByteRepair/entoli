import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_meta.dart";
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
    context: context,
  );

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
      reply(
        "a1",
        const ContextUsage(
          system: 4000,
          tools: 6000,
          profile: 200,
          chat: 20000,
        ),
      ),
      reply(
        "a2",
        const ContextUsage(system: 1000, tools: 2000, profile: 100, chat: 500),
        author: "@reviewer",
      ),
    ]);
    await app.pump(tester, ContextPage(chatId: id));
    await settleIo(tester);

    final house = tester.getTopLeft(find.text("Entoli Agent"));
    final member = tester.getTopLeft(find.text("@reviewer"));
    expect(house.dy, lessThan(member.dy));
    expect(find.text("Auto-compact 80%"), findsNWidgets(2));
    expect(
      tester.getSize(find.byTooltip("Chat: 20k tokens")).height,
      greaterThan(0),
    );
  });

  testWidgets("instructions are their own segment", (tester) async {
    final id = await seed(tester, [
      reply(
        "a1",
        const ContextUsage(
          system: 4000,
          tools: 6000,
          profile: 100,
          instructions: 3000,
          chat: 500,
        ),
      ),
    ]);
    await app.pump(tester, ContextPage(chatId: id));
    await settleIo(tester);

    expect(find.byTooltip("Instructions: 3.0k tokens"), findsOneWidget);
  });

  test("a reply measured before instructions were counted reads as none", () {
    final old = ContextUsage.fromJson({
      "system": 1,
      "tools": 2,
      "profile": 3,
      "chat": 4,
    });

    expect(old.instructions, 0);
    expect(old.estimated, 10);
  });

  testWidgets("the window is the chat's model's before any turn, and follows a "
      "change of model", (tester) async {
    app.backend.windowHolder["big"] = 1000000;
    app.backend.windowHolder["small"] = 32000;
    final id = await seed(tester, [
      reply(
        "a1",
        const ContextUsage(system: 4000, tools: 6000, profile: 0, chat: 10000),
      ),
    ]);
    await io(
      tester,
      () => app.repo.saveMeta(id, ChatMeta(model: "big", provider: "p")),
    );
    await app.pump(tester, ContextPage(chatId: id));
    await settleUntil(
      tester,
      () => find.text("20k / 1000k").evaluate().isNotEmpty,
      what: "the model's window",
    );

    await io(
      tester,
      () => app.repo.saveMeta(id, ChatMeta(model: "small", provider: "p")),
    );
    await settleUntil(
      tester,
      () => find.text("20k / 32k").evaluate().isNotEmpty,
      what: "the new model's window",
    );
  });

  testWidgets("a context past the window fills the bar without overflowing", (
    tester,
  ) async {
    final id = await seed(tester, [
      reply(
        "a1",
        const ContextUsage(system: 4000, tools: 6000, profile: 0, chat: 500000),
      ),
    ]);
    await app.pump(tester, ContextPage(chatId: id));
    await settleIo(tester);

    expect(tester.takeException(), isNull);
  });
}
