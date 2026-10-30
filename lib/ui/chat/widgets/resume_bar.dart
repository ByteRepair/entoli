import "package:flutter/material.dart";

import "../activity/format.dart";

/// Offered under a turn that never finished. Above the composer rather than in
/// the list, like the approval banner: scrolling back through the turn should
/// not lose the way to carry it on.
class ResumeBar extends StatelessWidget {
  const ResumeBar({
    super.key,
    required this.startedAt,
    required this.onContinue,
    this.notice,
  });

  final DateTime startedAt;
  final VoidCallback onContinue;

  /// An optional notice replacing the default "Unfinished turn" text — e.g.
  /// "Step limit reached" when the turn ended that way.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.pause_circle_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice ??
                  "Unfinished turn from ${formatAge(DateTime.now().difference(startedAt))}",
              style: theme.textTheme.bodySmall,
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: onContinue,
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text("Continue"),
          ),
        ],
      ),
    );
  }
}
