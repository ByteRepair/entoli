import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/goal.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/chat_page.dart" show GoalEntry, entriesOf;
import "package:agent_chat/ui/chat/widgets/goal_mark_row.dart";

import "../harness.dart" show makeState;

void main() {
  const paused = GoalMark(
    afterMessageId: "ask",
    change: GoalChange.paused,
    objective: "the tests pass",
    reason: "Paused by you.",
  );

  /// [mark]'s row, in the narrowest host that draws one.
  Future<void> pumpRow(WidgetTester tester, GoalMark mark) => tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: GoalMarkRow(mark: mark)),
      ),
    ),
  );

  testWidgets("a goal's row opens a drawer with its prompt and new state", (
    tester,
  ) async {
    await pumpRow(tester, paused);
    expect(find.text("Goal paused: the tests pass"), findsOneWidget);

    await tester.tap(find.text("Goal paused: the tests pass"));
    await tester.pumpAndSettle();

    expect(find.text("Now: paused"), findsOneWidget);
    expect(find.text("Paused by you."), findsOneWidget);
    expect(find.text(goalKickoff("the tests pass")), findsOneWidget);
  });

  testWidgets("an answer says no change rather than naming a state it has not "
      "left the goal in", (tester) async {
    const answered = GoalMark(
      afterMessageId: "ask",
      change: GoalChange.answered,
      objective: "No goal was set",
    );
    await pumpRow(tester, answered);
    expect(find.text("Goal answered: No goal was set"), findsOneWidget);

    await tester.tap(find.text("Goal answered: No goal was set"));
    await tester.pumpAndSettle();

    // Not "Now: no goal": the row moved nothing, and a goal may still stand.
    expect(find.text("No change"), findsOneWidget);
    // No kickoff was ever sent for this one, so there is no prompt to show.
    expect(find.textContaining("Goal prompt"), findsNothing);
  });

  test("the row goes after the message its record names", () {
    final at = DateTime.utc(2026, 11, 6);
    final chat = Chat(
      state: makeState("c"),
      messages: [
        Message(
          id: "ask",
          role: MessageRole.user,
          createdAt: at,
          parts: const [MessagePart.text(text: "/goal the tests pass")],
        ),
        Message(
          id: "reply",
          role: MessageRole.assistant,
          createdAt: at,
          parts: const [MessagePart.text(text: "On it.")],
        ),
      ],
      goals: const [paused],
    );

    final entries = entriesOf(chat);
    expect(entries[1], isA<GoalEntry>());
    expect((entries[1] as GoalEntry).mark, paused);
  });
}
