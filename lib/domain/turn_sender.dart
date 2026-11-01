/// How a turn sent by a [TurnSender] ended, in the three words its callers
/// say it in: a trigger's completion notification, a shortcut's result.
enum TurnOutcome { done, error, aborted }

/// Says a prompt in a chat, by id, and waits for the turn it starts to end —
/// for a caller with no chat page of its own: a trigger's fire, a shortcut.
/// The turn goes through the same `ChatController` the UI uses, so it is
/// the one the user sees if they open the chat while it runs. The
/// implementation lives in the UI layer; the domain only knows this.
///
/// Not `TurnDriver`, which is the controller's own face to its page.
abstract interface class TurnSender {
  /// [snippet] is the reply's text, for a caller that says what came of it.
  Future<({TurnOutcome outcome, String snippet})> send(
    String chatId,
    String prompt,
  );
}

/// Where a chat's turn stands, for a caller outside its page.
enum TurnStatus { idle, running, waitingForApproval, waitingForAnswer }

/// A chat's turn seen and stopped from outside its page — Shortcuts' — the
/// [TurnSender]'s other half. Implemented over the same controllers, and
/// never by building one: a chat nobody has open has no controller, and its
/// turn, if it has one, is the backend's alone.
abstract interface class TurnControl {
  TurnStatus statusOf(String chatId);

  /// Stops the turn running in [chatId], as the stop button does. False
  /// where none was running.
  Future<bool> stop(String chatId);
}
