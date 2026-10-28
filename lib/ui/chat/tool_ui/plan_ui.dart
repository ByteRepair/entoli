import "package:flutter/widgets.dart";

import "../../../domain/plan.dart";
import "../activity/activity.dart";
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

  bool _failed(Run run) => (run.result?.returnCode ?? 0) != 0;

  @override
  bool important(Run run) => !_failed(run);

  @override
  Widget build(Run run) => _failed(run) || run.call == null
      ? super.build(run)
      : PlanLabel(chatId: run.chatId, call: run.call!);
}
