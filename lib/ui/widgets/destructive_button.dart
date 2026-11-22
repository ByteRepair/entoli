import "package:flutter/material.dart";

import "../../core/log.dart";
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
    this.confirmMessageOf,
    this.confirmLabel = "Delete",
    required this.onConfirmed,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final String confirmTitle;
  final String confirmMessage;

  /// In place of [confirmMessage], asked for when pressed: a count read then
  /// rather than when the button was drawn.
  final Future<String> Function()? confirmMessageOf;
  final String confirmLabel;
  final Future<void> Function() onConfirmed;
  final bool enabled;

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
        onPressed: !enabled
            ? null
            : () async {
                var message = confirmMessage;
                try {
                  message = await confirmMessageOf?.call() ?? message;
                } catch (e) {
                  // The plain wording still asks; only the count is lost.
                  logFailure("ui", "could not word a confirmation", e);
                }
                if (!context.mounted) return;
                final confirmed = await confirm(
                  context,
                  title: confirmTitle,
                  message: message,
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
