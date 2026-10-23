import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../../widgets/action_icon.dart";

/// What the user has said to the running turn that it has not read yet, one
/// row each, above the composer. A row goes when the turn reads it, landing
/// in the reply. Each can still be sent after the turn instead, or taken back.
class SteerStrip extends StatelessWidget {
  const SteerStrip({
    super.key,
    required this.steering,
    required this.onQueue,
    this.onWithdraw,
  });

  final List<Message> steering;
  final ValueChanged<String> onQueue;
  /// Null where there is no composer to take a say back into.
  final ValueChanged<String>? onWithdraw;

  @override
  Widget build(BuildContext context) {
    if (steering.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final say in steering)
            Row(
              children: [
                Icon(Icons.subdirectory_arrow_right,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: _line(say),
                          style: theme.textTheme.bodyMedium),
                      TextSpan(text: "  at the next step", style: quiet),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ActionIcon(
                  icon: Icons.schedule_send,
                  tooltip: "Send after this turn instead",
                  onPressed: () => onQueue(say.id),
                ),
                if (onWithdraw case final withdraw?)
                  ActionIcon(
                    icon: Icons.close,
                    tooltip: "Take back",
                    onPressed: () => withdraw(say.id),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static final _space = RegExp(r"\s+");

  static String _line(Message say) {
    final text = say.plainText.trim().replaceAll(_space, " ");
    if (text.isNotEmpty) return text;
    return say.files.map((f) => f.filename).join(", ");
  }
}
