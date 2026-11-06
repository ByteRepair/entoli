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

  testWidgets("a goal's row opens a drawer with its prompt and new state", (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: GoalMarkRow(mark: paused)),
        ),
      ),
    );
    expect(find.text("Goal paused: the tests pass"), findsOneWidget);

    await tester.tap(find.text("Goal paused: the tests pass"));
    await tester.pumpAndSettle();

    expect(find.text("Now: paused"), findsOneWidget);
    expect(find.text("Paused by you."), findsOneWidget);
    expect(find.text(goalKickoff("the tests pass")), findsOneWidget);
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
