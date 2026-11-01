import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/chat_log.dart";
import "../../domain/turn_sender.dart";
import "chat_controller.dart";

/// Sends a turn — a trigger's, a shortcut's — through [ChatController], the
/// same path the user takes — the same path [VoiceController] takes when it speaks into a chat.
/// The controller is the single owner of `isRunning`, the recorder and the
/// event stream, so a turn started headlessly is the one the user sees if
/// they open the chat while it is running, and `interruptLiveTurns` reaches
/// it on the way out of the app.
///
/// For a chat already driving a turn, [send] waits for
/// that turn before speaking, so the `turnDone` it awaits after is its own.
class ChatControllerTurnSender implements TurnSender {
  ChatControllerTurnSender(this._ref);

  final Ref _ref;

  @override
  Future<({TurnOutcome outcome, String snippet})> send(
    String chatId,
    String prompt,
  ) async {
    final controller = _ref.read(chatControllerProvider(chatId).notifier);
    // Not the turn this send will start: whatever is running now. One await
    // covers a fan-out, the way the runner's own completion does.
    final running = controller.turnDone;
    if (running != null) await running;
    await controller.send(prompt);
    final reason = await controller.turnDone;
    final outcome = switch (reason) {
      TurnEnd.done => TurnOutcome.done,
      TurnEnd.error => TurnOutcome.error,
      TurnEnd.stepLimit => TurnOutcome.error,
      TurnEnd.aborted => TurnOutcome.aborted,
      null => TurnOutcome.aborted,
    };
    return (outcome: outcome, snippet: controller.replyText);
  }
}
