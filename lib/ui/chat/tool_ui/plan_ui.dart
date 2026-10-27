import "package:flutter/widgets.dart";

import "../../../domain/models.dart";
import "../../../domain/plan.dart";
import "../widgets/plan_view.dart" show PlanLabel;
import "tool_ui.dart";

/// The plan's own steps — `plan_add`, `plan_next`, `plan_done` — are not
/// worth saying aloud: the plan presented is.
class QuietPlanUI extends ToolUI {
  const QuietPlanUI(this.tool);

  @override
  final String tool;

  @override
  String? get spoken => null;
}

/// The plan put to the user is what the turn stopped to show, not activity on
/// the way to a reply: drawn as the plan itself, read off the file, until the
/// call fails.
class PresentPlanUI extends ToolUI {
  const PresentPlanUI();

  @override
  String get tool => presentPlanToolName;

  @override
  String get spoken => "Presented the plan";

  @override
  bool get prominent => true;

  @override
  Widget? label(ToolCall call, ToolResult? result, {required String chatId}) =>
      (result?.returnCode ?? 0) != 0 ? null : PlanLabel(chatId: chatId, call: call);
}
