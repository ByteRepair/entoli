import "package:flutter/material.dart";

/// The title over a group of settings, with a line under it saying what the
/// group is for. Shared out of `settings_page.dart` when the Voice category
/// grew a file of its own: a category drawn somewhere else has to look like the
/// ones beside it, and two copies of this would be two answers to the spacing.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
