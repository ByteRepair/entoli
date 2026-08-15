import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/question_panel.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  AskRequest request(List<AskQuestion> questions) =>
      AskRequest(id: "ask-1", questions: questions);

  const database = AskQuestion(
    question: "Which database?",
    summary: "Both are already in the stack.",
    options: [
      AskOption(label: "Postgres", detail: "Already running in staging."),
      AskOption(label: "SQLite", value: "sqlite"),
    ],
  );
  const migrate = AskQuestion(
    question: "Migrate the old rows?",
    options: [AskOption(label: "Yes"), AskOption(label: "No")],
  );

  /// A chat mid-turn, with [asked] on screen. The turn is held open, the way a
  /// real one is while the agent waits to be told.
  Future<String> asking(WidgetTester tester, AskRequest asked) async {
    app.backend.scriptedEvents = [QuestionRequestEvent(asked)];
    app.backend.hold = Completer<void>();
    addTearDown(() => app.backend.hold?.complete());

    final chat = await app.repo.createChat();
    final id = chat.state.id;
    app.container.read(selectedChatIdProvider.notifier).state = id;
    await app.pump(tester, const ChatPage(), settle: false);
    await pumpUntil(tester, find.byType(Composer));
    await app.container.read(chatControllerProvider(id).notifier).send("set up storage");
    await pumpUntil(tester, find.byType(QuestionPanel));
    return id;
  }

  /// Let the held turn finish. Answering restarts the stall clock, and a test
  /// that walks off leaving one ticking fails on the pending timer.
  Future<void> endTurn(WidgetTester tester, String id) async {
    app.backend.hold?.complete();
    app.backend.hold = null;
    for (var i = 0;
        i < 50 && app.container.read(chatControllerProvider(id)).isRunning;
        i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  }

  testWidgets("the composer gives way to the question", (tester) async {
    await asking(tester, request([database]));

    expect(find.byType(Composer), findsNothing);
    expect(find.text("Which database?"), findsOneWidget);
    expect(find.text("Both are already in the stack."), findsOneWidget);
    expect(find.text("Postgres"), findsOneWidget);
    expect(find.text("Already running in staging."), findsOneWidget);
    expect(find.text("Question 1 of 1"), findsOneWidget);
  });

  testWidgets("the bar counts the questions, and picking one moves on",
      (tester) async {
    await asking(tester, request([database, migrate]));
    expect(find.text("Question 1 of 2"), findsOneWidget);

    await tester.tap(find.text("Postgres"));
    await tester.pump();

    expect(find.text("Question 2 of 2"), findsOneWidget);
    expect(find.text("Migrate the old rows?"), findsOneWidget);
    // Nothing is sent until the last one is answered.
    expect(app.backend.answered, isEmpty);
  });

  testWidgets("answering the last one sends them all and gives the composer back",
      (tester) async {
    final id = await asking(tester, request([database, migrate]));

    await tester.tap(find.text("SQLite"));
    await tester.pump();
    await tester.tap(find.text("No"));
    await tester.pump();

    // The option's own value, not the label it was read under.
    expect(app.backend.answered.single.requestId, "ask-1");
    expect(app.backend.answered.single.answers, ["sqlite", "No"]);
    expect(app.container.read(chatControllerProvider(id)).questions, isEmpty);
    expect(find.byType(QuestionPanel), findsNothing);
    expect(find.byType(Composer), findsOneWidget);
    await endTurn(tester, id);
  });

  testWidgets("going back re-asks a question that was already answered",
      (tester) async {
    await asking(tester, request([database, migrate]));

    await tester.tap(find.text("Postgres"));
    await tester.pump();
    await tester.tap(find.text("Back"));
    await tester.pump();

    expect(find.text("Question 1 of 2"), findsOneWidget);
    expect(app.backend.answered, isEmpty);
  });

  testWidgets("skipping answers nothing rather than leaving the turn stuck",
      (tester) async {
    final id = await asking(tester, request([database, migrate]));

    await tester.tap(find.text("Skip"));
    await tester.pump();

    expect(app.backend.answered.single.answers, [null, null]);
    expect(find.byType(Composer), findsOneWidget);
    await endTurn(tester, id);
  });

  testWidgets("a turn that ends with one on screen takes it away", (tester) async {
    final id = await asking(tester, request([database]));

    app.backend.hold!.complete();
    app.backend.hold = null;
    await pumpUntil(tester, find.byType(Composer));

    expect(app.container.read(chatControllerProvider(id)).questions, isEmpty);
    expect(find.byType(QuestionPanel), findsNothing);
  });
}
