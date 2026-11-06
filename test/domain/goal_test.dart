import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/goal.dart";
import "package:agent_chat/domain/wired_skill.dart";

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

  test("setting and resuming a goal are the callbacks a model answers", () {
    expect(wiredSkillFromText("/goal")?.skill, WiredSkill.goal);
    expect(wiredRunsModel("/goal the tests pass"), isTrue);
    expect(wiredRunsModel("/goal resume"), isTrue);
    expect(wiredRunsModel("/goal pause"), isFalse);
    expect(wiredRunsModel("/goal"), isFalse);
    expect(wiredRunsModel("/compact"), isFalse);
    expect(
      goalObjectiveOf(wiredSkillFromText("/goal the tests pass")!),
      "the tests pass",
    );
    expect(goalObjectiveOf(wiredSkillFromText("/goal clear")!), isNull);
  });

  test("the goal survives the chat's meta, and a broken one is dropped", () {
    final meta = ChatMeta(
      goal: const ChatGoal(
        objective: "ship",
        status: GoalStatus.blocked,
        rounds: 3,
        stalls: 1,
        reason: "Needs a key.",
      ),
    );
    expect(ChatMeta.parse(meta.encode()).goal, meta.goal);
    expect(ChatMeta.parse('{"goal": {"status": "active"}}').goal, isNull);
    expect(ChatMeta.parse('{"sandbox": true, "goal": 3}').sandbox, isTrue);
  });
}
