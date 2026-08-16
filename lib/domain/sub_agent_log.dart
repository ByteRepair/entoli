import "chat_log.dart";
import "models.dart";

/// Where a `task` call's own transcript is kept, keyed by the call that spawned
/// it. The same `ChatRecord` log the conversation is — so `replay` reads it,
/// `projectionOf` puts it back in front of a model, and a missing `turnEnd`
/// means the same thing it means anywhere else: the process died mid-turn.
///
/// A port because the agent has to write one while it runs, and the backend is
/// the only thing that sees a sub-agent's events at all — they never reach the
/// controller that writes `conv.jsonl`.
abstract interface class SubAgentLog {
  Future<void> append(String callId, List<ChatRecord> records);

  /// What the sub-agent got to. Empty where it never wrote anything, which is
  /// the same answer as never having run.
  Future<List<Message>> read(String callId);

  /// Whether [callId]'s log stops in the middle of a turn, so the sub-agent is
  /// one to carry on rather than one that finished. Named for `TurnEnd.resumable`,
  /// which is what decides it. `false` for a log that is not there.
  Future<bool> isResumable(String callId);
}

/// A [SubAgentLog] for a chat that has nowhere to write — the tests that drive
/// an agent directly, and any caller that has not opted in.
class NoSubAgentLog implements SubAgentLog {
  const NoSubAgentLog();

  @override
  Future<void> append(String callId, List<ChatRecord> records) async {}

  @override
  Future<List<Message>> read(String callId) async => const [];

  @override
  Future<bool> isResumable(String callId) async => false;
}
