import "../agent_backend.dart";
import "../chat_repository.dart";
import "../goal.dart";
import "../models.dart";

/// A participant that takes turns. Each answers in a session of its own,
/// which the backend keys by the handle; this is the room's hold on it.
class Agent {
  Agent(this._repo, this.chatId, this.handle, {this.goal});

  final ChatRepository _repo;
  final String chatId;
  final String handle;

  /// The room's goal as it stands, which the turn reads at every stop.
  final GoalReader? goal;

  /// Answer [say]. [history] ends before it; [replaces] says the session holds
  /// a thread [say] does not continue; [mayDecline] says the participant may
  /// answer it with `end_turn` rather than a reply.
  ///
  /// Pre: no other turn of this agent runs in the room.
  /// Post: the stream closes when the turn is over.
  Stream<AgentEvent> take(
    Message say, {
    required List<Message> history,
    required List<ConversationCompaction> compactions,
    bool replaces = false,
    required bool mayDecline,
    SteerInbox? steers,
  }) => _repo.sendPrompt(
    chatId,
    say,
    history: history,
    compactions: compactions,
    replaces: replaces,
    participant: handle,
    mayDecline: mayDecline,
    steers: steers,
    goal: goal,
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
    goal: goal,
  );
}
