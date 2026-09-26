import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/prompts/bundled_skill_data.dart"
    show bundledSkillFiles;
import "package:agent_chat/domain/models.dart" show CompletionKind;
import "package:agent_chat/domain/prompt_library.dart"
    show PromptDocument, PromptLibrary, promptDocuments;
import "package:agent_chat/domain/wired_skill.dart"
    show WiredSkill, wiredSkillFromText;

void main() {
  test("a wired name dispatches with its arguments", () {
    expect(wiredSkillFromText("/compact")?.skill, WiredSkill.compact);
    expect(wiredSkillFromText("/compact keep the greeting")?.arguments,
        "keep the greeting");
    // A name the enum does not carry is prose, whatever its frontmatter.
    expect(wiredSkillFromText("/review"), isNull);
  });

  test("composition refuses to expand a callback skill's body", () {
    final doc = PromptDocument.parse(
        CompletionKind.skill,
        "compact",
        "---\nname: compact\ndescription: do compact\nmetadata:\n  invocation: \"callback\"\n---\n\nUser-facing note.\n");
    final library = PromptLibrary([doc]);
    expect(promptDocuments("/compact focus here", library), isEmpty);
  });

  test("every bundled skill flagged callback is one the enum implements", () {
    for (final file in bundledSkillFiles) {
      if (file.binary || !file.relativePath.endsWith("SKILL.md")) continue;
      final document = PromptDocument.parse(
          CompletionKind.skill, file.name, file.content);
      if (!document.isCallback) continue;
      expect(wiredSkillFromText("/${document.name}"), isNotNull,
          reason:
              "${file.name} is flagged invocation: callback but the enum does not implement it: it degrades to template expansion");
    }
  });
}
