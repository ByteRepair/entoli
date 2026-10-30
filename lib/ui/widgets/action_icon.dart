import "package:flutter/material.dart";

/// The small icon button the chat uses for what can be done to a message, and
/// to a block inside one. Compact enough to sit in a row under a bubble or on
/// a code block's bar without either growing to fit it.
class ActionIcon extends StatelessWidget {
  const ActionIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  /// Also the height the actions row keeps whether or not anything is in it,
  /// so the conversation does not shift as the icons appear.
  static const height = 28.0;

  final IconData icon;
  final String tooltip;

  /// Null is the dead form — an arrow at either end of the threads, which
  /// stays where it is rather than letting the row close up around it.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(icon, size: 16),
    tooltip: tooltip,
    onPressed: onPressed,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 32, height: height),
  );
}
