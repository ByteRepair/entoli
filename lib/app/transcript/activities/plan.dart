import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/plan.dart";
import "../../../domain/tool_arg.dart";
import "../../plan.dart" show planProgressLine, planProvider;
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";
import "tool_run.dart";

/// The plan's own steps — `plan_add`, `plan_next`, `plan_done` — are not
/// worth saying aloud: the plan presented is.
final class QuietPlanActivity extends ToolActivity {
  const QuietPlanActivity(this.tool);

  @override
  final String tool;

  @override
  String? get spoken => null;
}

/// The plan put to the user is what the turn stopped to show, not activity on
/// the way to a reply: shown as the plan itself, read off the file, until the
/// call fails.
final class PresentPlanActivity extends ToolActivity {
  const PresentPlanActivity();

  @override
  String get tool => presentPlanToolName;

  @override
  String get spoken => "Presented the plan";

  @override
  bool important(Run run) => !run.failed;

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final call = run.call;
    if (run.failed || call == null) return super.node(reader, run);
    // Read off the file rather than the call, so it shows where the work
    // stands now, and is built again as the plan moves.
    final plan = reader.watch(planProvider(run.chatId));
    return PlanNode(
      this,
      run,
      title: stringArg(call.argumentsJson, "title") ?? "Plan",
      sections: plan.value,
      progress: planProgressLine(plan.value, loading: plan.isLoading),
    );
  }
}
