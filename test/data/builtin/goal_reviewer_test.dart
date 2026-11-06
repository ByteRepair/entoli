import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/goal_reviewer.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";

void main() {
  test("a verdict is read out of whatever the reviewer wrapped it in", () {
    final verdict = LlmGoalReviewer.parseVerdict(
      'Here:\n```json\n{"verdict": "continue", "reason": "No test run.", '
      '"next": "Run them."}\n```',
    );
    expect(verdict?.kind, GoalVerdictKind.carryOn);
    expect(verdict?.reason, "No test run.");
    expect(verdict?.next, "Run them.");
    expect(
      LlmGoalReviewer.parseVerdict('{"verdict": "met"}')?.kind,
      GoalVerdictKind.met,
    );
    expect(LlmGoalReviewer.parseVerdict('{"verdict": "maybe"}'), isNull);
    expect(LlmGoalReviewer.parseVerdict("Yes, it is met."), isNull);
  });

  test("the reviewer reads the conversation's end, not its start", () {
    final long = "x" * (LlmGoalReviewer.transcriptBudget * 2);
    final prompt = LlmGoalReviewer.reviewPrompt("ship", [
      const LlmMessage(role: LlmRole.system, text: "SYSTEM PROMPT"),
      const LlmMessage(role: LlmRole.user, text: "FIRST"),
      for (var i = 0; i < 20; i++) LlmMessage(role: LlmRole.tool, text: long),
      const LlmMessage(role: LlmRole.assistant, text: "LAST"),
    ]);
    expect(prompt, contains("<goal>\nship\n</goal>"));
    expect(prompt, contains("LAST"));
    expect(prompt, isNot(contains("FIRST")));
    expect(prompt, isNot(contains("SYSTEM PROMPT")));
  });
}
