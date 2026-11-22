import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/context_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Message reply(String id, ContextUsage context, {String? author}) => Message(
    id: id,
    role: MessageRole.assistant,
    createdAt: DateTime.utc(2026),
    author: author,
    context: context,
  );

  testWidgets("a card per participant, with what fills their window", (
    tester,
  ) async {
    final chat = await io(tester, () => app.seedChat());
    await io(
      tester,
      () => app.writeChat(
        chat.copyWith(
          messages: [
            reply(
              "a1",
              const ContextUsage(
                system: 4000,
                tools: 6000,
                profile: 200,
                instructions: 3000,
                chat: 20000,
              ),
            ),
            reply(
              "a2",
              const ContextUsage(system: 100, tools: 100, profile: 0, chat: 50),
              author: "@reviewer",
            ),
          ],
        ),
      ),
    );
    await app.pump(tester, ContextPage(chatId: chat.state.id));
    await pumpUntil(tester, find.text("@reviewer"));

    expect(find.byType(Card), findsNWidgets(2));
    final names = tester
        .widgetList<Text>(find.textContaining(RegExp("^@")))
        .map((t) => t.data);
    expect(names, ["@athena", "@reviewer"]);
    // One bar each, its parts laid end to end and named under it.
    expect(find.text("Instructions"), findsNWidgets(2));
    expect(find.text("3.0k"), findsOneWidget);
    expect(find.text("Auto-compact 80%"), findsNWidgets(2));
    expect(find.byTooltip("Instructions: 3.0k tokens"), findsOneWidget);
    expect(find.textContaining("four characters a token"), findsOneWidget);
  });

  testWidgets("nothing measured says so", (tester) async {
    final chat = await io(tester, () => app.seedChat());
    await app.pump(tester, ContextPage(chatId: chat.state.id));

    expect(find.text("Nothing measured yet"), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });
}
