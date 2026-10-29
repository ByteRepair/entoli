import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart" show ToolCall;
import "../../../domain/plan.dart";
import "../../../domain/tool_arg.dart";
import "../activity/activity.dart";
import "../plan_page.dart";
import "../widgets/plan_view.dart" show PlanTaskList, planProvider;
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
      : _PlanLabel(chatId: run.chatId, call: run.call!);
}

/// A `present_plan` call, drawn as the plan it put to the user: every task,
/// each opening to its details. Read off the file rather than the call, so
/// it shows where the work stands now.
class _PlanLabel extends ConsumerWidget {
  const _PlanLabel({required this.chatId, required this.call});

  final String chatId;
  final ToolCall call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final title = stringArg(call.argumentsJson, "title") ?? "Plan";
    final plan = ref.watch(planProvider(chatId));
    final sections = plan.value;
    // The whole width of the reply's column, like the reply itself: task
    // details are prose, and a narrow card wrapped them into a ribbon.
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.checklist),
            title: Text(title, style: theme.textTheme.titleMedium),
            subtitle: Text(switch (sections) {
              final sections? => _progress(sections),
              // A mirror's first read is a round trip to the home device.
              null when plan.isLoading => "Reading the plan…",
              null => "The plan could not be read.",
            }),
            trailing: sections == null
                ? null
                : IconButton(
                    tooltip: "Open the plan",
                    icon: const Icon(Icons.open_in_full),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PlanPage(chatId: chatId)),
                    ),
                  ),
          ),
          if (sections != null) PlanTaskList(sections: sections),
        ],
      ),
    );
  }
}

String _progress(List<PlanSection> sections) {
  final (done, total) = sectionsProgress(sections);
  return "$done of $total tasks done";
}
