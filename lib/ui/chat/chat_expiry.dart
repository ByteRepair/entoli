import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/chat_controller.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../selection.dart";
import "../widgets/dialogs.dart";

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
  // Not dismissed: the chat is kept or deleted, one or the other.
  final keep = !await confirm(
    context,
    title: "Temporary chat expired",
    message:
        "This temporary chat has passed its expiry. Turn temporary chat off "
        "to keep it, or delete it now.",
    confirmLabel: "Delete",
    cancelLabel: "Keep",
    destructive: true,
    dismissible: false,
  );
  if (!context.mounted) return;
  final repo = container.read(chatRepositoryProvider);
  if (keep) {
    final written = await repo.keepExpiredChat(chatId, state);
    container.read(chatControllerProvider(chatId).notifier).applyState(written);
  } else {
    container.read(selectedChatIdProvider.notifier).select(null);
    await repo.deleteChat(chatId);
  }
  container.invalidate(chatListProvider);
}
