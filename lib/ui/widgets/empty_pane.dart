import "package:flutter/material.dart";

/// The middle of a page with nothing on it. Shared so that two states of the
/// same page cannot drift apart by a few pixels of padding — see AGENTS.md.
class EmptyPane extends StatelessWidget {
  const EmptyPane({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = this.detail;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(title),
            // An empty detail is no detail line at all — an empty Text still
            // takes its line's height and reads as a stray gap.
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(detail, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            ],
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}
