import "package:flutter/widgets.dart";

import "../../../domain/models.dart";
import "../../../domain/plan.dart";
import "../widgets/plan_view.dart" show PlanLabel;
import "tool_ui.dart";

/// The plan's own steps are not worth saying aloud: the plan presented is.
abstract class _QuietPlanUI extends ToolUI {
  const _QuietPlanUI();

  @override
  String? get spoken => null;
}

class PlanAddUI extends _QuietPlanUI {
  const PlanAddUI();

  @override
  String get tool => planAddToolName;
}

class PlanNextUI extends _QuietPlanUI {
  const PlanNextUI();

  @override
  String get tool => planNextToolName;
}

class PlanDoneUI extends _QuietPlanUI {
  const PlanDoneUI();

  @override
  String get tool => planDoneToolName;
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
