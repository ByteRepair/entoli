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
