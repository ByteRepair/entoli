import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_definition.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

AgentDefinition agentFrom(String source) =>
    AgentDefinition.of(PromptDocument.parse(CompletionKind.agent, "a", source));

void main() {
  group("an agent's tools", () {
    test("are absent where the file names none, and each tool's default "
        "decides", () {
      final agent = agentFrom("---\ndescription: d\n---\nBody.");
      expect(agent.tools, isNull);
      expect(agent.offers("bash", byDefault: true), isTrue);
      expect(agent.offers("bash(readonly)", byDefault: false), isFalse);
    });

    test("are exactly the list where there is one", () {
      final agent = agentFrom("---\ntools: read, bash(readonly)\n---\nBody.");
      expect(agent.tools, {"read", "bash(readonly)"});
      expect(agent.offers("bash(readonly)", byDefault: false), isTrue);
      expect(agent.offers("write", byDefault: true), isFalse);
    });

    test("read the same from a YAML list, and an empty one is none", () {
      expect(agentFrom("---\ntools:\n  - read\n  - grep\n---\nB").tools,
          {"read", "grep"});
      expect(agentFrom("---\ntools: [read]\n---\nB").tools, {"read"});
      expect(agentFrom("---\ntools: []\n---\nB").tools, isEmpty);
    });

    test("read from a file the strict parse refuses", () {
      // The `: ` in the description is not YAML, so the legacy parser reads it.
      final agent =
          agentFrom("---\ndescription: say it: plainly\ntools: read\n---\nB");
      expect(agent.description, "say it: plainly");
      expect(agent.tools, {"read"});
    });
  });

  test("the main agent has no instructions and every default", () {
    expect(AgentDefinition.main.instructions, "");
    expect(AgentDefinition.main.offers("read", byDefault: true), isTrue);
  });

  group("writing an agent back", () {
    test("reads back as what was edited, keys it does not edit kept", () {
      final agent = agentFrom("---\ndescription: old\nmodel: big\n"
              "metadata:\n  colour: red\n---\nOld body.")
          .edited(
        name: "a",
        description: "new: with a colon",
        instructions: "New body.",
        tools: {"read", "bash(readonly)"},
      );
      final back = agentFrom(agent.toSource());
      expect(back.description, "new: with a colon");
      expect(back.instructions, "New body.");
      expect(back.tools, {"read", "bash(readonly)"});
      expect(back.document!.frontmatter["model"], "big");
      expect(back.document!.metadata, {"colour": "red"});
    });

    test("writes no list where the tools are left at their defaults, and "
        "an empty one as none", () {
      final defaults = agentFrom("---\ntools: read\n---\nB").edited(
          name: "a", description: "", instructions: "B", tools: null);
      expect(defaults.toSource(), isNot(contains("tools")));
      expect(agentFrom(defaults.toSource()).tools, isNull);

      final none = defaults.edited(
          name: "a", description: "", instructions: "B", tools: {});
      expect(agentFrom(none.toSource()).tools, isEmpty);
    });
  });
}
