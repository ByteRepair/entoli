import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/tools/agent_tool.dart";
import "package:agent_chat/data/builtin/tools/bash_tool.dart";
import "package:agent_chat/data/builtin/tools/customization_tools.dart";
import "package:agent_chat/data/builtin/tools/registry.dart";
import "package:agent_chat/domain/agent_definition.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

AgentDefinition looker() => AgentDefinition.of(
  PromptDocument.parse(
    CompletionKind.agent,
    "looker",
    "---\ntools: read, bash(readonly)\n---\nB",
  ),
);

Set<String> offered(ToolOffer offer) => {
  for (final tool in offeredTools(offer)) tool.name,
};

void main() {
  test("the read-only shell offers no way out of the sandbox", () {
    const offer = ToolOffer(sandboxed: true);
    expect(BashTool(offer).schema["properties"], contains("unsandboxed"));
    expect(
      ReadOnlyBashTool(offer).schema["properties"],
      isNot(contains("unsandboxed")),
    );
  });

  test("the settings tools are the agent's to be granted", () {
    expect(
      offered(const ToolOffer(customizing: true)),
      containsAll([setProfileName, setToneName]),
    );
    expect(
      offered(ToolOffer(customizing: true, agent: looker())),
      isNot(anyOf(contains(setProfileName), contains(setToneName))),
    );
  });
}
