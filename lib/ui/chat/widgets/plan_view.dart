import "package:flutter/material.dart";

import "../../../domain/plan.dart";

export "../../../app/plan.dart";
import "message_text.dart" show MessageText;

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
