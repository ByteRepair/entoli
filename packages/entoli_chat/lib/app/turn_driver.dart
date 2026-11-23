import "../domain/models.dart";
import "../domain/reaction.dart";

/// What a page needs of whatever is driving its turn. `ChatController` for a
/// chat on this device, `MirrorChatController` for one whose home device is a
/// paired peer — the widgets between them are the same either way, and only
/// where the work happens differs.
abstract interface class TurnDriver {
  /// While a turn runs, [text] steers it unless [queue] holds it for after.
  Future<void> send(String text, {List<Attachment> attachments, bool queue});

  /// A say still waiting for its turn to read it, sent after the turn instead.
  Future<void> queueSteer(String id);

  /// Take back a say its turn has not read yet: what it was sent with, or
  /// null where the turn already has it.
  Future<Draft?> withdrawSteer(String id);

  /// Whether [text], sent now, would steer the running turn rather than be
  /// queued after it.
  bool steers(String text);

  Future<void> resume();
  Future<void> abort();
  Future<void> respondApproval(
    String approvalId,
    ApprovalResponse r, {
    ToolApproval? approval,
  });
  Future<void> answerQuestions(String requestId, List<String?> answers);
  Future<void> editAndResend(String messageId, String text);
  Future<void> regenerate(String messageId);

  /// React to any message, the user's own included — said to whoever wrote
  /// it — or take back a reaction it already has.
  Future<void> react(String messageId, Reaction reaction);

  Future<void> stepThread(String messageId, int step);
  Future<void> deleteThread(String messageId);

  /// Whether an approval answer may write a standing rule here. False for a
  /// mirrored chat: the banner is being answered from the other device, and
  /// the rule is the home device's to write — its banner asks the question,
  /// so offering it twice would be two answers to one call.
  bool get rulesWritable => true;
}
