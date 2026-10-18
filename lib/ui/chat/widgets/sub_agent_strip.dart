import "package:flutter/material.dart";

import "../../../domain/agent_backend.dart";

/// A row of chips showing the sub-agents a turn has spawned and is still
/// running. Up to four are listed; the rest collapse into a "+N agents" chip.
/// Sits above the composer and the approval banners, since it is turn-scoped
/// view state like they are, not a message.
class SubAgentStrip extends StatelessWidget {
  const SubAgentStrip({super.key, required this.agents});

  final List<SubAgentStartEvent> agents;

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final visible = agents.take(4).toList();
    final overflow = agents.length - visible.length;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final agent in visible) ...[
              if (agent != visible.first) const SizedBox(width: 6),
              _Chip(
                text: "@${agent.agent}",
                color: theme.colorScheme.onPrimaryContainer,
                background: theme.colorScheme.primaryContainer,
                weight: FontWeight.w500,
              ),
            ],
            if (overflow > 0) ...[
              const SizedBox(width: 6),
              _Chip(
                text: "+$overflow ${overflow == 1 ? "agent" : "agents"}",
                color: theme.colorScheme.onSurfaceVariant,
                background: theme.colorScheme.surfaceContainerHighest,
                border: theme.colorScheme.outlineVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A running agent, or the count of those past the first four.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.text,
    required this.color,
    required this.background,
    this.border,
    this.weight,
  });

  final String text;
  final Color color;
  final Color background;
  final Color? border;
  final FontWeight? weight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: border == null ? null : Border.all(color: border!),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: color, fontWeight: weight),
          ),
        ],
      ),
    );
  }
}
