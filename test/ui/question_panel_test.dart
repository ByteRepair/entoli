import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/question_panel.dart";

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
    options: [
      AskOption(label: "Yes"),
      AskOption(label: "No"),
    ],
  );

  Future<String> asking(
    WidgetTester tester,
    AskRequest asked, {
    EdgeInsets bars = EdgeInsets.zero,
  }) => heldTurn(
    tester,
    app,
    event: QuestionRequestEvent(asked),
    until: find.byType(QuestionPanel),
    prompt: "set up storage",
    bars: bars,
  );

  /// Let the held turn finish — the composer goes back to offering `send` when
  /// it has.
  Future<void> endTurn(WidgetTester tester) async {
    app.backend.hold?.complete();
    app.backend.hold = null;
    await pumpUntil(tester, find.byIcon(Icons.send));
  }

  testWidgets("the composer gives way to the question", (tester) async {
    await asking(tester, request([database]));

    expect(find.byType(Composer), findsNothing);
    expect(find.text("Which database?"), findsOneWidget);
    expect(find.text("Both are already in the stack."), findsOneWidget);
    expect(find.text("Postgres"), findsOneWidget);
    expect(find.text("Already running in staging."), findsOneWidget);
  });

  // `Question 1 of 1` over a single segment, with two arrows that can only be
  // dead, is the `1/1` the thread counter leaves out for the same reason.
  testWidgets("one question is not counted, and has nowhere to move", (
    tester,
  ) async {
    await asking(tester, request([database]));

    expect(find.text("Question 1 of 1"), findsNothing);
    expect(find.text("Back"), findsNothing);
    expect(find.text("Next"), findsNothing);
    expect(find.text("Skip"), findsOneWidget);
  });

  testWidgets("the bar counts the questions, and picking one moves on", (
    tester,
  ) async {
    await asking(tester, request([database, migrate]));
    expect(find.text("Question 1 of 2"), findsOneWidget);

    await tester.tap(find.text("Postgres"));
    await tester.pump();

    expect(find.text("Question 2 of 2"), findsOneWidget);
    expect(find.text("Migrate the old rows?"), findsOneWidget);
    // Nothing is sent until the last one is answered.
    expect(app.backend.answered, isEmpty);
  });

  // Picking the last option used to submit the lot, which left no moment in
  // which an answer already given could be looked at again.
  testWidgets("answering every question sends nothing until Send is pressed", (
    tester,
  ) async {
    final id = await asking(tester, request([database, migrate]));

    await tester.tap(find.text("SQLite"));
    await tester.pump();
    await tester.tap(find.text("No"));
    await tester.pump();
    expect(app.backend.answered, isEmpty);
    expect(find.byType(QuestionPanel), findsOneWidget);

    await tester.tap(find.text("Send"));
    await tester.pump();

    // The option's own value, not the label it was read under.
    expect(app.backend.answered.single.requestId, "ask-1");
    expect(app.backend.answered.single.answers, ["sqlite", "No"]);
    expect(
      app.container
          .read(chatControllerProvider(id))
          .questions
          .values
          .every((q) => q.isEmpty),
      isTrue,
    );
    expect(find.byType(QuestionPanel), findsNothing);
    expect(find.byType(Composer), findsOneWidget);
    await endTurn(tester);
  });

  // The composer is gone while the panel is up, so an answer that is not on
  // the list is typed into the question itself.
  testWidgets("a typed answer is picked by typing, and sent as its text", (
    tester,
  ) async {
    await asking(tester, request([database]));

    await tester.enterText(find.byType(TextField).last, "  MySQL, actually ");
    await tester.pump();
    expect(find.text("Send"), findsOneWidget);
    // Picking an option takes over from the typed answer, and the field keeps
    // its text for going back to.
    await tester.tap(find.text("Postgres"));
    await tester.pump();
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    await tester.tap(find.text("Send"));
    await tester.pump();

    expect(app.backend.answered.single.answers, ["MySQL, actually"]);
    await endTurn(tester);
  });

  testWidgets("a cleared typed answer answers nothing", (tester) async {
    await asking(tester, request([database]));

    await tester.enterText(find.byType(TextField).last, "MySQL");
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, "");
    await tester.pump();

    expect(find.text("Skip"), findsOneWidget);
  });

  // One button and one action. Two names for it would be two promises, and
  // which one it is is the whole of what "nothing picked" changes.
  testWidgets("the button offers to skip until something is picked", (
    tester,
  ) async {
    await asking(tester, request([database, migrate]));
    expect(find.text("Skip"), findsOneWidget);
    expect(find.text("Send"), findsNothing);

    await tester.tap(find.text("Postgres"));
    await tester.pump();

    expect(find.text("Send"), findsOneWidget);
    expect(find.text("Skip"), findsNothing);
  });

  group("moving between them", () {
    /// The segment standing for [question], which is the way to jump straight
    /// to one rather than stepping through what is in between.
    Finder segmentFor(String question) => find.byTooltip(question);

    Finder step(String label) => find.widgetWithText(TextButton, label);

    testWidgets("a segment jumps straight to its question", (tester) async {
      await asking(tester, request([database, migrate]));

      await tester.tap(segmentFor("Migrate the old rows?"));
      await tester.pump();

      expect(find.text("Question 2 of 2"), findsOneWidget);
      expect(app.backend.answered, isEmpty);
    });

    testWidgets("Next moves on without answering, and Back comes back", (
      tester,
    ) async {
      await asking(tester, request([database, migrate]));

      await tester.tap(find.text("Next"));
      await tester.pump();
      expect(find.text("Question 2 of 2"), findsOneWidget);

      await tester.tap(find.text("Back"));
      await tester.pump();
      expect(find.text("Question 1 of 2"), findsOneWidget);
      expect(app.backend.answered, isEmpty);
    });

    // They stop rather than wrapping round, the way the thread arrows under a
    // message do: one that comes back to where the reader started has done
    // nothing they can see.
    testWidgets("they are dead at either end", (tester) async {
      await asking(tester, request([database, migrate]));
      expect(enabled(tester, step("Back")), isFalse);
      expect(enabled(tester, step("Next")), isTrue);

      await tester.tap(find.text("Next"));
      await tester.pump();

      expect(enabled(tester, step("Back")), isTrue);
      expect(enabled(tester, step("Next")), isFalse);
    });

    testWidgets("an answer given earlier can be changed before sending", (
      tester,
    ) async {
      await asking(tester, request([database, migrate]));
      await tester.tap(find.text("Postgres"));
      await tester.pump();
      await tester.tap(find.text("No"));
      await tester.pump();

      await tester.tap(segmentFor("Which database?"));
      await tester.pump();
      await tester.tap(find.text("SQLite"));
      await tester.pump();
      await tester.tap(find.text("Send"));
      await tester.pump();

      expect(app.backend.answered.single.answers, ["sqlite", "No"]);
      await endTurn(tester);
    });
  });

  testWidgets("going back re-asks a question that was already answered", (
    tester,
  ) async {
    await asking(tester, request([database, migrate]));

    await tester.tap(find.text("Postgres"));
    await tester.pump();
    await tester.tap(find.text("Back"));
    await tester.pump();

    expect(find.text("Question 1 of 2"), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(app.backend.answered, isEmpty);
  });

  testWidgets("skipping answers nothing rather than leaving the turn stuck", (
    tester,
  ) async {
    await asking(tester, request([database, migrate]));

    await tester.tap(find.text("Skip"));
    await tester.pump();

    expect(app.backend.answered.single.answers, [null, null]);
    expect(find.byType(Composer), findsOneWidget);
    await endTurn(tester);
  });

  testWidgets("a turn that ends with one on screen takes it away", (
    tester,
  ) async {
    final id = await asking(tester, request([database]));

    await endTurn(tester);

    expect(app.container.read(chatControllerProvider(id)).questions, isEmpty);
    expect(find.byType(QuestionPanel), findsNothing);
  });

  testWidgets("the options stay clear of the navigation bar", (tester) async {
    const bars = EdgeInsets.only(bottom: 48);
    await asking(tester, request([database]), bars: bars);

    final panel = tester.getRect(find.byType(QuestionPanel));
    final last = tester.getRect(find.text("SQLite"));
    expect(panel.bottom - last.bottom, greaterThanOrEqualTo(bars.bottom));
  });
}
