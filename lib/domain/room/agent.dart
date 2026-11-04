import "../agent_backend.dart";
import "../chat_repository.dart";
import "../models.dart";

/// A participant that takes turns. Each answers in a session of its own,
/// which the backend keys by the handle; this is the room's hold on it.
class Agent {
  Agent(this._repo, this.chatId, this.handle);

  final ChatRepository _repo;
  final String chatId;
  final String handle;

  /// Answer [say]. [history] ends before it; [replaces] says the session holds
  /// a thread [say] does not continue.
  ///
  /// Pre: no other turn of this agent runs in the room.
  /// Post: the stream closes when the turn is over.
  Stream<AgentEvent> take(
    Message say, {
    required List<Message> history,
    required List<ConversationCompaction> compactions,
    bool replaces = false,
    SteerInbox? steers,
  }) => _repo.sendPrompt(
    chatId,
    say,
    history: history,
    compactions: compactions,
    replaces: replaces,
    participant: handle,
    steers: steers,
  );

  /// Carry on the turn [history] ends in.
  ///
  /// Pre and post as [take].
  Stream<AgentEvent> carryOn({
    required List<Message> history,
    required List<ConversationCompaction> compactions,
    SteerInbox? steers,
  }) => _repo.resumeTurn(
    chatId,
    history: history,
    compactions: compactions,
    participant: handle,
    steers: steers,
  );
}
