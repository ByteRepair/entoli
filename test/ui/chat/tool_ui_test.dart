import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/tools/agent_tool.dart";
import "package:agent_chat/data/builtin/tools/registry.dart";
import "package:agent_chat/ui/chat/activity/activity.dart" show Run;
import "package:agent_chat/ui/chat/tool_ui/tool_ui.dart";

void main() {
  // A UI is paired with its tool by the name alone, so a rename on either
  // side leaves a UI drawing nothing: this is what catches it.
  test("every tool UI names a tool there is", () {
    final tools = {for (final tool in agentTools(const ToolOffer())) tool.name};
    for (final ui in toolUIs) {
      expect(tools, contains(ui.tool), reason: "${ui.runtimeType}");
    }
  });

  test("one UI per tool", () {
    final names = [for (final ui in toolUIs) ui.tool];
    expect(names.toSet().length, names.length);
  });

  test("a tool with no UI of its own gets the defaults", () {
    final ui = toolUIFor("memory_save");
    expect(ui.spoken, "Used memory_save");
    expect(ui.approval.$2, "Allow memory_save?");
    expect(ui.important(const Run(chatId: "c", callId: "x")), isFalse);
  });
}
