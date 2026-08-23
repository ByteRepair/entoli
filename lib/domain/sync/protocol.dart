import "package:freezed_annotation/freezed_annotation.dart";

import "../chat_log.dart";
import "../chat_meta.dart";
import "../models.dart";
import "identity.dart";

part "protocol.freezed.dart";
part "protocol.g.dart";

/// Everything two Entolis say to each other once the channel is up. One
/// sealed union so the dispatcher cannot forget an arm: add a message and
/// every switch over [SyncMessage] stops compiling until it is handled.
///
/// The handshake and the first `hello` exchange are not here — they run
/// before any application traffic (`handshake.dart`, `_establish`) and stay
/// hand-rolled JSON beside them.
///
/// Commands never travel. A prompt sent from a mirror is *run* on the chat's
/// home device, through the same `ChatController` a local one goes through —
/// what comes back is the ordinary record stream. What the control arms move
/// is who may type, not where the work happens.
@freezed
sealed class SyncMessage with _$SyncMessage {
  /// The home device's chat list, sent right after `hello` and again
  /// whenever it changes. Whole-list replacement: lists are small, deltas
  /// would be a second truth about what a mirror holds.
  const factory SyncMessage.welcome({
    required List<ChatState> chats,
    @Default(SyncIdentity.protocolVersion) int proto,
  }) = SyncWelcome;

  const factory SyncMessage.chatsChanged({
    required List<ChatState> chats,
  }) = SyncChatsChanged;

  /// Subscribe to one of the peer's chats from record [fromLine] on — the
  /// count of records the asking side already holds. Zero is a fresh open.
  const factory SyncMessage.chatOpen({
    required String chatId,
    @Default(0) int fromLine,
  }) = SyncChatOpen;

  /// The reply to [SyncChatOpen]: state, meta and the records from
  /// [SyncChatOpen.fromLine]. [totalLines] is the log's length at send time,
  /// which is where the next resume counts from.
  const factory SyncMessage.chatSnapshot({
    required String chatId,
    required ChatState state,
    required ChatMeta meta,
    required List<ChatRecord> records,
    required int totalLines,
  }) = SyncChatSnapshot;

  /// Records appended to a subscribed chat since the last delivery. A
  /// snapshot plus these in order rebuilds the log exactly.
  const factory SyncMessage.recordAppend({
    required String chatId,
    required List<ChatRecord> records,
  }) = SyncRecordAppend;

  /// The chat's head moved: title, pin, project, TTL anchors. Carries the
  /// whole [ChatState] rather than a field diff — every turn rewrites
  /// updatedAt, so per-field patches would be wrong more often than whole.
  const factory SyncMessage.stateDiff({
    required String chatId,
    required ChatState state,
  }) = SyncStateDiff;

  const factory SyncMessage.metaPatch({
    required String chatId,
    required ChatMeta meta,
  }) = SyncMetaPatch;

  const factory SyncMessage.chatDeleted({required String chatId}) =
      SyncChatDeleted;

  const factory SyncMessage.chatMoved({
    required String chatId,
    String? project,
  }) = SyncChatMoved;

  /// Ask for an attachment's bytes. Correlated by [id], which the chunks
  /// carry back.
  const factory SyncMessage.resourceRequest({
    required String id,
    required String chatId,
    required String resource,
  }) = SyncResourceRequest;

  /// One frame of a resource's bytes, base64. [done] marks the last.
  const factory SyncMessage.resourceChunk({
    required String id,
    required String bytesB64,
    @Default(false) bool done,
  }) = SyncResourceChunk;

  /// Liveness. Thirty seconds unanswered drops the peer to offline.
  const factory SyncMessage.ping() = SyncPing;

  const factory SyncMessage.pong() = SyncPong;

  // ---- Control, and driving a turn from the other end. ------------------

  /// Who holds the chat, as the home device sees it — a device id, or null
  /// for nobody. Pushed to every subscriber whenever it changes, so a second
  /// mirror watching the same chat sees that someone else has it.
  const factory SyncMessage.controlState({
    required String chatId,
    String? holder,
  }) = SyncControlState;

  const factory SyncMessage.controlRequest({required String chatId}) =
      SyncControlRequest;

  const factory SyncMessage.controlGrant({
    required String chatId,
    required bool granted,
  }) = SyncControlGrant;

  const factory SyncMessage.controlRelease({required String chatId}) =
      SyncControlRelease;

  /// The turn-scoped view state a mirror cannot get from the log: whether one
  /// is running, what it is waiting to be allowed or told, and the line the
  /// spinner is on. Sent whole on every change — it is small, and a diff
  /// would be a second account of what is pending.
  const factory SyncMessage.turnState({
    required String chatId,
    @Default(false) bool running,
    @Default(<ToolApproval>[]) List<ToolApproval> approvals,
    @Default(<SyncAsk>[]) List<SyncAsk> asks,
    String? status,
    String? retry,
  }) = SyncTurnState;

  const factory SyncMessage.promptSend({
    required String chatId,
    required String text,
  }) = SyncPromptSend;

  const factory SyncMessage.approvalRespond({
    required String chatId,
    required String approvalId,
    required bool allow,
  }) = SyncApprovalRespond;

  const factory SyncMessage.questionsRespond({
    required String chatId,
    required String requestId,
    required List<String?> answers,
  }) = SyncQuestionsRespond;

  const factory SyncMessage.turnAbort({required String chatId}) =
      SyncTurnAbort;

  /// Carry on a turn the home device was cut off in.
  const factory SyncMessage.turnResume({required String chatId}) =
      SyncTurnResume;

  factory SyncMessage.fromJson(Map<String, dynamic> json) =>
      _$SyncMessageFromJson(json);
}

/// One `ask_user` call on the wire. The questions themselves are not sent:
/// they are read out of the call's arguments by `askQuestionsFrom`, which is
/// what the home device did with the same string — so a mirror renders the
/// panel from the model's own words rather than from a second encoding of
/// them.
@freezed
abstract class SyncAsk with _$SyncAsk {
  const factory SyncAsk({
    required String id,
    String? argumentsJson,
  }) = _SyncAsk;

  factory SyncAsk.fromJson(Map<String, dynamic> json) =>
      _$SyncAskFromJson(json);
}
