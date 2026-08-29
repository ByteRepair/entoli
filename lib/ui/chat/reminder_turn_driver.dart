import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/chat_log.dart";
import "../../domain/reminder_runner.dart";
import "chat_controller.dart";

/// Drives a reminder's turn through [ChatController], the same path the user
/// takes — the same path [VoiceController] takes when it speaks into a chat.
/// The controller is the single owner of `isRunning`, the recorder and the
/// event stream, so a turn started headlessly is the one the user sees if they
/// open the chat while it is running, and `interruptLiveTurns` reaches it on
/// the way out of the app.
class ChatControllerReminderTurnDriver implements ReminderTurnDriver {
  ChatControllerReminderTurnDriver(this._ref);

  final Ref _ref;

  @override
  Future<({ReminderOutcome outcome, String snippet})> send(
      String chatId, String prompt) async {
    final controller = _ref.read(chatControllerProvider(chatId).notifier);
    await controller.send(prompt);
    final reason = await controller.turnDone;
    final outcome = switch (reason) {
      TurnEnd.done => ReminderOutcome.done,
      TurnEnd.error => ReminderOutcome.error,
      TurnEnd.stepLimit => ReminderOutcome.error,
      TurnEnd.aborted => ReminderOutcome.aborted,
      null => ReminderOutcome.aborted,
    };
    return (outcome: outcome, snippet: controller.replyText);
  }
}
