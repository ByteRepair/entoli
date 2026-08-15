import "package:flutter/material.dart";

import "dialogs.dart";

/// A danger-colored filled button that asks for confirmation before running
/// [onConfirmed]. Used by the chat, project, and "delete all" settings entries
/// so the styling and confirmation flow are not reimplemented per page.
class DestructiveButton extends StatelessWidget {
  const DestructiveButton({
    super.key,
    required this.icon,
    required this.label,
    required this.confirmTitle,
    required this.confirmMessage,
    this.confirmLabel = "Delete",
    required this.onConfirmed,
  });

  final IconData icon;
  final String label;
  final String confirmTitle;
  final String confirmMessage;
  final String confirmLabel;
  final Future<void> Function() onConfirmed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FilledButton.icon(
        icon: Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
          foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
        ),
        onPressed: () async {
          final confirmed = await confirm(
            context,
            title: confirmTitle,
            message: confirmMessage,
            confirmLabel: confirmLabel,
            destructive: true,
          );
          if (!confirmed) return;
          await onConfirmed();
        },
      ),
    );
  }
}