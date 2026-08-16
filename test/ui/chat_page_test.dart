import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";
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
    await settleIo(tester);
  }

  /// A conversation taller than the window, so there is somewhere to scroll.
  Future<Chat> seedLongChat(
    WidgetTester tester, {
    String title = "at home",
    String? project,
    int messages = 40,
  }) =>
      io(tester, () async {
        final chat = await app.repo.createChat(title: title, project: project);
        final said = [
          for (var i = 0; i < messages; i++)
            Message(
              id: "m$i",
              role: i.isEven ? MessageRole.user : MessageRole.assistant,
              createdAt: DateTime(2026, 1, 1, 0, i),
              parts: [TextPart(text: "line $i")],
            ),
        ];
        final full = chat.copyWith(messages: said);
        await app.repo.save(full);
        return full;
      });

  ScrollPosition position(WidgetTester tester) =>
      tester.widget<Scrollable>(find.byType(Scrollable).first).controller!.position;

  testWidgets("a chat opens at its latest message", (tester) async {
    final chat = await seedLongChat(tester);

    await open(tester, chat.state.id);

    expect(position(tester).pixels, position(tester).maxScrollExtent);
    expect(find.text("line 39"), findsOneWidget);
    expect(find.text("line 0"), findsNothing);
  });

  testWidgets("the bar names the app at the top and the chat below it",
      (tester) async {
    final chat = await seedLongChat(tester, title: "at work", project: "work");

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("at work")),
        findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text("work")),
        findsOneWidget);
    expect(find.text("Entoli"), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("Entoli")),
        findsOneWidget);
    expect(find.text("at work"), findsNothing);
  });

  // Every chat is in one, so naming the default on all of them says nothing.
  testWidgets("a chat in the default project is titled and nothing more",
      (tester) async {
    final chat = await seedLongChat(tester, title: "at home");

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("at home")),
        findsOneWidget);
    expect(find.text("Default"), findsNothing);
  });

  // Nothing to scroll is the top, so a fresh chat is the app's own front page.
  testWidgets("an empty chat keeps the app's name up", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "brand new"));

    await open(tester, chat.state.id);

    expect(find.text("Entoli"), findsOneWidget);
  });

  group("keeping up with a turn", () {
    testWidgets("there is no jump button while the end is in view", (tester) async {
      final chat = await seedLongChat(tester);

      await open(tester, chat.state.id);

      expect(find.byTooltip("Jump to latest"), findsNothing);
    });

    testWidgets("scrolling back offers the way down again", (tester) async {
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);

      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();

      expect(find.byTooltip("Jump to latest"), findsOneWidget);

      await tester.tap(find.byTooltip("Jump to latest"));
      await tester.pumpAndSettle();

      expect(position(tester).pixels, position(tester).maxScrollExtent);
      expect(find.byTooltip("Jump to latest"), findsNothing);
    });

    testWidgets("a reply arriving while the reader is up the page leaves it there",
        (tester) async {
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      final held = position(tester).pixels;

      app.backend.scriptedEvents = [const TextDelta("and another thing"), const DoneEvent()];
      await io(
        tester,
        () => app.container.read(chatControllerProvider(chat.state.id).notifier).send("more"),
      );
      await settleIo(tester);

      expect(position(tester).pixels, held);
      expect(find.byTooltip("Jump to latest"), findsOneWidget);
    });
  });

  /// How visible each message's row of actions currently is.
  Iterable<double> revealed(WidgetTester tester) => tester
      .widgetList<AnimatedOpacity>(find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byType(AnimatedOpacity),
      ))
      .map((o) => o.opacity);

  // Only the message that was touched: each keeps its own actions covered.
  testWidgets("touching a message uncovers that one's actions", (tester) async {
    final chat = await seedLongChat(tester, messages: 4);
    await open(tester, chat.state.id);

    await tester.tap(find.text("line 0"), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(MessageBubble), findsNWidgets(4));
    expect(revealed(tester).where((o) => o == 1), hasLength(1));
  });

  // Starting a scroll on a message is not the same as touching it.
  testWidgets("dragging the list from a message leaves it covered", (tester) async {
    final chat = await seedLongChat(tester);
    await open(tester, chat.state.id);

    final gesture = await tester.startGesture(tester.getCenter(find.text("line 39")));
    await gesture.moveBy(const Offset(0, 40));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text("line 39"), findsOneWidget);
    expect(revealed(tester).where((o) => o == 1), isEmpty);
  });
}
