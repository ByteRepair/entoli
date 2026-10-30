import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/plan.dart";
import "../../../providers.dart";
import "../mirror_controller.dart" show chatViewProvider;
import "message_text.dart" show MessageText;

/// The chat's `PLAN.md`, parsed; null where there is none or it could not be
/// read. A mirrored chat's is asked of its home device over the sync channel.
/// Read again when [planRevision] moves rather than watched, since every
/// write to the file lands in the conversation as a result.
final planProvider = FutureProvider.autoDispose
    .family<List<PlanSection>?, String>((ref, chatId) async {
      ref.watch(
        chatViewProvider(
          chatId,
        ).select((view) => planRevision(view.chat?.messages ?? const [])),
      );
      final text = ref.watch(isMirroredChatProvider(chatId))
          ? await ref.read(syncHubProvider).planText(chatId)
          : await ref.read(chatRepositoryProvider).readPlan(chatId);
      final sections = planSectionsFrom(text);
      return sections.isEmpty ? null : sections;
    });

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
              child: Text(
                section.heading,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
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
      PlanTaskStatus.inProgress => (
        Icons.timelapse,
        scheme.tertiary,
        "In progress",
      ),
      PlanTaskStatus.pending => (
        Icons.radio_button_unchecked,
        scheme.outline,
        "To do",
      ),
    };
    final title = Text("${task.index}. ${task.text}");
    final leading = Tooltip(
      message: status,
      child: Icon(icon, color: colour),
    );
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
            text: task.details,
            isError: false,
            isWaiting: false,
            caret: false,
          ),
        ),
      ],
    );
  }
}
