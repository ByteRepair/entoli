import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/chat_edits.dart";
import "package:entoli_chat/domain/models.dart";
import "stand_in_bar.dart";

/// Why an imported chat has no composer, and the two ways to enable it.
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
          .read(chatEditsProvider)
          .enable(widget.chat, keepWorkspace: keepWorkspace);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => StandInBar(
    icon: Icons.shield_outlined,
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
