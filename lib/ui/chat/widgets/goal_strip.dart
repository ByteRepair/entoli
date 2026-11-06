import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/goal.dart";
import "../../../providers.dart" show chatGoalProvider;
import "../../widgets/action_icon.dart";

/// The chat's goal, one row above the composer while there is one: what it
/// is, where it stands, and the buttons `/goal pause`, `resume` and `clear`
/// are — pressed, each is sent as that command, so the composer and the row
/// are one route. See "Goals" in `lib/domain/AGENTS.md`.
class GoalStrip extends ConsumerWidget {
  const GoalStrip({super.key, required this.chatId, required this.onCommand});

  final String chatId;

  /// Sends `/goal <verb>` the way the composer would.
  final ValueChanged<String> onCommand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(chatGoalProvider(chatId)).value;
    if (goal == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, label, colour) = switch (goal.status) {
      GoalStatus.active => (Icons.track_changes, "Goal", scheme.primary),
      GoalStatus.paused => (
        Icons.pause_circle_outline,
        "Goal paused",
        scheme.onSurfaceVariant,
      ),
      GoalStatus.met => (
        Icons.check_circle_outline,
        "Goal met",
        scheme.primary,
      ),
      GoalStatus.blocked => (Icons.block, "Goal blocked", scheme.error),
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
            Icon(icon, size: 16, color: colour),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: "$label  ", style: quiet),
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
                onPressed: () => onCommand("/goal pause"),
              )
            else if (goal.status != GoalStatus.met)
              ActionIcon(
                icon: Icons.play_arrow,
                tooltip: "Resume the goal",
                onPressed: () => onCommand("/goal resume"),
              ),
            ActionIcon(
              icon: Icons.close,
              tooltip: "Clear the goal",
              onPressed: () => onCommand("/goal clear"),
            ),
          ],
        ),
      ),
    );
  }
}
