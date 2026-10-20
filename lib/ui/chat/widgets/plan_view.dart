import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart" show ToolCall;
import "../../../domain/plan.dart";
import "../../../domain/tool_arg.dart";
import "../../../providers.dart";
import "../mirror_controller.dart" show chatViewProvider;
import "../plan_page.dart";
import "message_bubble.dart" show MessageText;

/// The chat's `PLAN.md`, parsed; null where there is none or it could not be
/// read. A mirrored chat's is asked of its home device over the sync channel.
/// Read again when [planRevision] moves rather than watched, since every
/// write to the file lands in the conversation as a result.
final planProvider =
    FutureProvider.autoDispose.family<List<PlanSection>?, String>((ref, chatId) async {
  ref.watch(chatViewProvider(chatId)
      .select((view) => planRevision(view.chat?.messages ?? const [])));
  final text = ref.watch(isMirroredChatProvider(chatId))
      ? await ref.read(syncHubProvider).planText(chatId)
      : await ref.read(chatRepositoryProvider).readPlan(chatId);
  final sections = planSectionsFrom(text);
  return sections.isEmpty ? null : sections;
});

/// The app bar's way to the plan, there only while the chat has one.
class PlanButton extends ConsumerWidget {
  const PlanButton({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(planProvider(chatId)).value;
    if (sections == null) return const SizedBox.shrink();
    final tasks = [for (final s in sections) ...s.tasks];
    final done = tasks.where((t) => t.status == PlanTaskStatus.done).length;
    return IconButton(
      tooltip: "Plan, $done of ${tasks.length} done",
      icon: const Icon(Icons.checklist),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlanPage(chatId: chatId)),
      ),
    );
  }
}

/// A `present_plan` call, drawn as the plan it put to the user: every task,
/// each opening to its details. Read off the file rather than the call, so
/// it shows where the work stands now.
class PlanLabel extends ConsumerWidget {
  const PlanLabel({super.key, required this.chatId, required this.call});

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
  final tasks = [for (final s in sections) ...s.tasks];
  final done = tasks.where((t) => t.status == PlanTaskStatus.done).length;
  return "$done of ${tasks.length} tasks done";
}

/// The plan's tasks under their headings, each opening to its details. The
/// headings show only where the plan has more than one.
class PlanTaskList extends StatelessWidget {
  const PlanTaskList({super.key, required this.sections});

  final List<PlanSection> sections;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in sections) ...[
          if (sections.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(section.heading,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary)),
            ),
          for (final task in section.tasks) _PlanTaskTile(task: task),
        ],
      ],
    );
  }
}

class _PlanTaskTile extends StatelessWidget {
  const _PlanTaskTile({required this.task});

  final PlanTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, colour, status) = switch (task.status) {
      PlanTaskStatus.done => (Icons.check_circle, scheme.primary, "Done"),
      PlanTaskStatus.inProgress => (Icons.timelapse, scheme.tertiary, "In progress"),
      PlanTaskStatus.pending => (Icons.radio_button_unchecked, scheme.outline, "To do"),
    };
    final title = Text("${task.index}. ${task.text}");
    final leading = Tooltip(message: status, child: Icon(icon, color: colour));
    if (task.details.isEmpty) {
      return ListTile(leading: leading, title: title);
    }
    return ExpansionTile(
      leading: leading,
      title: title,
      shape: const Border(),
      collapsedShape: const Border(),
      childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionArea(
          child: MessageText(
              text: task.details, isError: false, isWaiting: false, caret: false),
        ),
      ],
    );
  }
}
