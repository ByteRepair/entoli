import "package:flutter/material.dart";

import "../../../domain/goal.dart";
import "../../widgets/action_icon.dart";

/// The chat's goal, one row above the composer while there is one: what it
/// is, where it stands, and the buttons `/goal pause`, `resume` and `clear`
/// are — pressed, each is sent as that command, so the composer and the row
/// are one route. See "Goals" in `lib/domain/AGENTS.md`.
class GoalStrip extends StatelessWidget {
  const GoalStrip({super.key, required this.goal, required this.onCommand});

  /// The chat's goal as its log leaves it; null draws nothing.
  final ChatGoal? goal;

  /// Sends `/goal <verb>` the way the composer would.
  final ValueChanged<String> onCommand;

  @override
  Widget build(BuildContext context) {
    final goal = this.goal;
    if (goal == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = switch (goal.status) {
      GoalStatus.active || GoalStatus.met => scheme.primary,
      GoalStatus.paused => scheme.onSurfaceVariant,
      GoalStatus.blocked => scheme.error,
    };
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Tooltip(
      message: goalSummary(goal),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(goalStatusIcon(goal.status), size: 16, color: colour),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: "${goalStatusLabel(goal.status)}  ",
                      style: quiet,
                    ),
                    TextSpan(
                      text: goal.objective,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (goal.isActive)
              ActionIcon(
                icon: Icons.pause,
                tooltip: "Pause the goal",
                onPressed: () => onCommand(const GoalPause().text),
              )
            else if (goal.status != GoalStatus.met)
              ActionIcon(
                icon: Icons.play_arrow,
                tooltip: "Resume the goal",
                onPressed: () => onCommand(const GoalResume().text),
              ),
            ActionIcon(
              icon: Icons.close,
              tooltip: "Clear the goal",
              onPressed: () => onCommand(const GoalClear().text),
            ),
          ],
        ),
      ),
    );
  }
}

/// A goal standing at [status], as an icon — the row's, and the marks that
/// leave it there.
IconData goalStatusIcon(GoalStatus status) => switch (status) {
  GoalStatus.active => Icons.track_changes,
  GoalStatus.paused => Icons.pause_circle_outline,
  GoalStatus.met => Icons.check_circle_outline,
  GoalStatus.blocked => Icons.block,
};
