import "package:flutter/widgets.dart";

import "../../../domain/agent_backend.dart" show taskToolName;
import "../../../domain/models.dart";
import "../widgets/activity_label.dart" show TaskLabel;
import "tool_ui.dart";

/// A sub-agent's call, drawn as the drawer that follows its transcript.
class TaskUI extends ToolUI {
  const TaskUI();

  @override
  String get tool => taskToolName;

  @override
  String get spoken => "Ran a sub-agent";

  @override
  Widget label(ToolCall call, ToolResult? result, {required String chatId}) =>
      TaskLabel(chatId: chatId, call: call, result: result);
}
