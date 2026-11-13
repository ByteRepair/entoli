import "package:flutter/material.dart";

import "../../fonts.dart";

/// One thing the chat has running, as a pill in the row above the composer:
/// a spinner, or [icon] where there is one, and what it is.
class RunningPill extends StatelessWidget {
  const RunningPill({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.mono = false,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = theme.colorScheme.onPrimaryContainer;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ActionChip(
        avatar: icon == null
            ? runningSpinner(colour)
            : Icon(icon, size: 16, color: colour),
        label: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: mono
              ? TextStyle(fontFamily: monoFamily, fontSize: 12, color: colour)
              : theme.textTheme.labelMedium?.copyWith(
                  color: colour,
                  fontWeight: FontWeight.w500,
                ),
        ),
        backgroundColor: theme.colorScheme.primaryContainer,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: onPressed,
      ),
    );
  }
}

/// The small spinner of a pill or a group of them.
Widget runningSpinner(Color colour) => SizedBox(
  width: 12,
  height: 12,
  child: CircularProgressIndicator(strokeWidth: 1.5, color: colour),
);
