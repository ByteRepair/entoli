import "../domain/ask.dart" show AskRequest;
import "../domain/models.dart" show ToolApproval;
import "../domain/room/room_state.dart";

/// What a running turn puts on screen above whatever answers it — the
/// offer to carry on, the question, the approvals — and when each shows, for
/// every frontend that draws a turn.
extension type const TurnSurfaceModel(ChatViewState view) {
  /// The offer to carry on an interrupted turn, from when it started. Only
  /// while nothing runs: the turn carried on is the one at the end, so the
  /// offer and the work are never both on screen.
  ({DateTime startedAt, String? notice})? get resume {
    final chat = view.chat;
    if (chat == null || !chat.unfinished || view.isRunning) return null;
    return (
      startedAt: chat.messages.last.createdAt,
      notice: view.unfinishedNotice,
    );
  }

  /// What the turn waits to be told, while the room waits on the user. One
  /// panel, the first turn's: a room with two asking is a round that
  /// misfired — nobody answers two panels at once, and the second is still
  /// there when the first is answered.
  AskRequest? get asked => view.roomPhase == RoomPhase.waitingOnYou
      ? view.questions.values.expand((q) => q).firstOrNull
      : null;

  /// The calls waiting to be allowed, each turn's in turn.
  Iterable<ToolApproval> get approvals =>
      view.approvals.values.expand((a) => a);
}
