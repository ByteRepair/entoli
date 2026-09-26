import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart" show CompletionKind;
import "package:agent_chat/domain/prompt_library.dart" show PromptDocument;
import "package:agent_chat/domain/wired_skill.dart"
    show WiredSkill, wiredSkillFrom;

void main() {
  test("isCallback reads the invocation key", () {
    final doc = PromptDocument.parse(
        CompletionKind.skill,
        "compact",
        "---\nname: compact\ndescription: do compact\nmetadata:\n  invocation: \"callback\"\n---\n\nDo compact.\n");
    expect(doc.isCallback, isTrue);
    expect(wiredSkillFrom(doc), WiredSkill.compact);
  });
}