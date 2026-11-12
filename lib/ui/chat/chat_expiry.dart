import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/chat_controller.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../selection.dart";

/// A temporary chat whose window has passed is offered a choice between
/// keeping it — its TTL turned off — and deleting it, asked over [context].
/// The chat page asks once per open, and so does the native shell's open
/// chat, which has no page building to ask from.
Future<void> checkChatExpiry(
  BuildContext context,
  String chatId,
  ChatState state,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (!state.isExpired()) return;
  if (!context.mounted) return;
  final keep = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text("Temporary chat expired"),
      content: const Text(
        "This temporary chat has passed its expiry. Turn temporary chat off "
        "to keep it, or delete it now.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text("Keep"),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text("Delete"),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  final repo = container.read(chatRepositoryProvider);
  if (keep == true) {
    final written = await repo.keepExpiredChat(chatId, state);
    container.read(chatControllerProvider(chatId).notifier).applyState(written);
  } else {
    container.read(selectedChatIdProvider.notifier).select(null);
    await repo.deleteChat(chatId);
  }
  container.invalidate(chatListProvider);
}
