import "package:flutter/material.dart";

/// One muted line where a pane would otherwise be blank — a project with no
/// chats in it, a search nothing answered, a paired device's list with nothing
/// picked out of it. Shared because two of them are on screen at once, the
/// sidebar's beside the chat pane's.
///
/// [EmptyPane] is the other size of the same idea: an icon, a heading and
/// somewhere to go, for a page rather than a strip of one.
class Nothing extends StatelessWidget {
  const Nothing(this.said, {super.key});

  final String said;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: Text(
          said,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
