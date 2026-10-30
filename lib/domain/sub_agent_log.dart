import "dart:async";

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

/// Records added to a sub-agent's transcript, numbered from [from]: the count
/// the transcript held before them.
typedef SubAgentAppend = ({
  String chatId,
  String callId,
  int from,
  List<ChatRecord> records,
});

/// The transcripts of the sub-agents running now, held in memory as they are
/// written, and every append as it lands. What the `task` drawer follows, here
/// and on a paired device; a run that is over is read off disk instead.
///
/// Appends are numbered rather than only ordered because a reader takes its
/// snapshot and subscribes at two different moments, and the stream delivers
/// later than it is written to. [growTranscript] is how a reader reconciles.
class SubAgentFeed {
  final _held = <(String, String), List<ChatRecord>>{};
  final _appends = StreamController<SubAgentAppend>.broadcast();

  Stream<SubAgentAppend> get appends => _appends.stream;

  /// [callId]'s transcript so far, or null where it is not running here.
  List<ChatRecord>? held(String chatId, String callId) {
    final records = _held[(chatId, callId)];
    return records == null ? null : List.unmodifiable(records);
  }

  bool holds(String chatId, String callId) =>
      _held.containsKey((chatId, callId));

  /// Start holding a run, from what its log already has: a sub-agent carried
  /// on adds to the transcript it was killed in.
  void open(String chatId, String callId, List<ChatRecord> existing) =>
      _held[(chatId, callId)] = [...existing];

  /// [records] were written. A `turnEnd` is the run over, and its transcript
  /// is the file's to answer for from then on.
  void add(String chatId, String callId, List<ChatRecord> records) {
    final key = (chatId, callId);
    final held = _held[key];
    if (held == null || records.isEmpty) return;
    final from = held.length;
    held.addAll(records);
    if (records.any((r) => r is TurnEndRecord)) _held.remove(key);
    if (!_appends.isClosed) {
      _appends.add((
        chatId: chatId,
        callId: callId,
        from: from,
        records: records,
      ));
    }
  }

  Future<void> close() => _appends.close();
}

/// [held] with an append numbered from [from] added: what it already has is
/// skipped, and null is a gap — records were missed, so read it again.
List<ChatRecord>? growTranscript(
  List<ChatRecord> held,
  int from,
  List<ChatRecord> records,
) {
  if (from > held.length) return null;
  final skip = held.length - from;
  if (skip >= records.length) return held;
  return [...held, ...records.skip(skip)];
}
