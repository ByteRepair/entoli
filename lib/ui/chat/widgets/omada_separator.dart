import "package:flutter/material.dart";

/// A room whose Omada mode changed, said between the turns either side of
/// it. Metadata rather than a message: full width, untinted, not selectable
/// — the same furniture the labels above a bubble are. The caption names
/// the flip, so a mixed-mode chat explains its own sections on a reload.
class OmadaSeparator extends StatelessWidget {
  const OmadaSeparator({super.key, required this.omada});

  /// The mode the room entered at this boundary.
  final bool omada;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              omada ? "Omada is turned on" : "Omada is turned off",
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
        ],
      ),
    );
  }
}