import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/chat_edits.dart";
import "package:entoli_chat/core/log.dart";
import "package:entoli_chat/domain/models.dart";
import "package:entoli_chat/ui/widgets/dialogs.dart" show say;
import "../../../providers.dart" show isMirroredChatProvider;
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
    } catch (e) {
      logFailure("chat", "enabling imported chat ${widget.chat.id} failed", e);
      if (mounted) say(context, "Could not enable this chat: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A mirror's is its home device's to enable.
    if (ref.watch(isMirroredChatProvider(widget.chat.id))) {
      return const StandInBar(
        icon: Icons.shield_outlined,
        text:
            "This conversation is imported, and is enabled on the device it "
            "is on.",
      );
    }
    return _bar();
  }

  Widget _bar() => StandInBar(
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
