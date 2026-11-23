import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/chat_shares.dart";
import "../../../domain/models.dart";

/// Why an imported chat has no composer, and the two ways to enable it.
/// Follows `NeedsSetupBar`'s shape.
class ImportedBar extends ConsumerStatefulWidget {
  const ImportedBar({super.key, required this.chat});

  final ChatState chat;

  @override
  ConsumerState<ImportedBar> createState() => _ImportedBarState();
}

class _ImportedBarState extends ConsumerState<ImportedBar> {
  bool _busy = false;

  Future<void> _enable({required bool keepWorkspace}) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(chatSharesProvider)
          .enable(widget.chat, keepWorkspace: keepWorkspace);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SharedChatBar(
    text:
        "This conversation is imported, make sure you trust it before "
        "running it. Any previous message, thinking fragment, or file could "
        "be malicious.",
    actions: [
      TextButton(
        onPressed: _busy ? null : () => _enable(keepWorkspace: false),
        child: const Text("Enable Chat"),
      ),
      FilledButton.tonal(
        onPressed: _busy ? null : () => _enable(keepWorkspace: true),
        child: const Text("Enable and Import"),
      ),
    ],
  );
}

/// The frame both imported bars are drawn in: a warning and its buttons.
class SharedChatBar extends StatelessWidget {
  const SharedChatBar({super.key, required this.text, required this.actions});

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: color, fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}
