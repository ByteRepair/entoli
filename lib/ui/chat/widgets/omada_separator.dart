import "package:flutter/material.dart";

/// A boundary said between the turns either side of it. Metadata rather than a
/// message: full width, untinted, not selectable — the same furniture the
/// labels above a bubble are. The caption names it, so a conversation explains
/// its own boundaries on a reload.
///
/// Two boundaries share it: the room's Omada mode changing, and a compaction
/// — the divider naming where the conversation's summary for the model began.
/// The tap is the compaction's, the summary being the one thing a boundary
/// has to show.
class ConversationSeparator extends StatelessWidget {
  const ConversationSeparator({
    super.key,
    required this.text,
    this.onTap,
  });

  /// What the divider says happened here.
  final String text;

  /// Where the summary behind a boundary is shown, where there is one to
  /// show. Null for a boundary that is only a line — a mode flip.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
          onTap == null
              ? caption
              : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6),
                  child: caption),
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
        ],
      ),
    );
  }
}