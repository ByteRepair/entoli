import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/goal.dart";
import "package:agent_chat/domain/wired_skill.dart";

import "../harness.dart" show makeState;

void main() {
  test("one word that is a verb is the verb; anything else an objective", () {
    expect(goalCommandOf(""), isA<GoalShow>());
    expect(goalCommandOf(" Pause "), isA<GoalPause>());
    expect(goalCommandOf("resume"), isA<GoalResume>());
    for (final word in ["clear", "stop", "off", "reset", "none", "cancel"]) {
      expect(goalCommandOf(word), isA<GoalClear>(), reason: word);
    }
    expect(
      goalCommandOf("pause the build on red"),
      isA<GoalSet>().having(
        (g) => g.objective,
        "objective",
        "pause the build on red",
      ),
    );
  });

  test("a command's text reads back as that command", () {
    for (final command in const <GoalCommand>[
      GoalSet("ship it"),
      GoalShow(),
      GoalPause(),
      GoalResume(),
      GoalClear(),
    ]) {
      final wired = wiredSkillFromText(command.text)!;
      expect(wired.skill, WiredSkill.goal);
      expect(goalCommandOf(wired.arguments).runtimeType, command.runtimeType);
    }
  });

  test("setting and resuming a goal are the callbacks a model answers", () {
    expect(wiredSkillFromText("/goal")?.skill, WiredSkill.goal);
    expect(wiredRunsModel("/goal the tests pass"), isTrue);
    expect(wiredRunsModel("/goal resume"), isTrue);
    expect(wiredRunsModel("/goal pause"), isFalse);
    expect(wiredRunsModel("/goal"), isFalse);
    expect(wiredRunsModel("/compact"), isFalse);
  });

  group("the goal is the log's", () {
    final at = DateTime.utc(2026, 11, 6);
    Message said(String id, MessageRole role) => Message(
      id: id,
      role: role,
      createdAt: at,
      parts: [MessagePart.text(text: id)],
    );
    ChatRecord mark(String after, GoalChange change, {String? reason}) =>
        ChatRecord.goal(
          afterMessageId: after,
          change: change,
          objective: "ship",
          reason: reason,
        );

    test("replay folds the records into the goal a restart reloads", () {
      final records = [
        ...recordsOf([
          said("ask", MessageRole.user),
          said("reply", MessageRole.assistant),
        ]),
        mark("ask", GoalChange.set),
        mark("reply", GoalChange.blocked, reason: "Needs a key."),
      ];
      final chat = chatFrom(makeState("c"), records);

      expect(chat.goals.map((g) => g.change), [
        GoalChange.set,
        GoalChange.blocked,
      ]);
      expect(
        chat.goal,
        const ChatGoal(
          objective: "ship",
          status: GoalStatus.blocked,
          reason: "Needs a key.",
        ),
      );
      // Cleared, there is none; resumed after a pause, it runs again.
      expect(goalOf([...chat.goals, _mark(GoalChange.cleared)]), isNull);
      expect(
        goalOf([
          ...chat.goals,
          _mark(GoalChange.paused),
          _mark(GoalChange.resumed),
        ]),
        const ChatGoal(objective: "ship"),
      );
    });

    test("a rewind past where it was set takes the goal with it", () {
      final records = [
        ...recordsOf([said("first", MessageRole.user)]),
        ...recordsOf([said("ask", MessageRole.user)]),
        mark("ask", GoalChange.set),
        const ChatRecord.rewind(messageId: "ask"),
      ];
      final chat = chatFrom(makeState("c"), records);

      expect(chat.goals, isEmpty);
      expect(chat.goal, isNull);
    });

    test("a mark about another goal moves nothing", () {
      expect(
        goalOf([
          _mark(GoalChange.set),
          const GoalMark(
            afterMessageId: "m",
            change: GoalChange.met,
            objective: "an older goal",
          ),
        ]),
        const ChatGoal(objective: "ship"),
      );
    });
  });
}

GoalMark _mark(GoalChange change) =>
    GoalMark(afterMessageId: "m", change: change, objective: "ship");
