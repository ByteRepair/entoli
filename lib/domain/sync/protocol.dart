import "package:freezed_annotation/freezed_annotation.dart";

import "../app_settings.dart";
import "../chat_log.dart";
import "../chat_meta.dart";
import "../models.dart";
import "../project_settings.dart";
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
/// what comes back is the ordinary record stream.
@freezed
sealed class SyncMessage with _$SyncMessage {
  /// The home device's chat list, sent right after `hello` and again
  /// whenever it changes. Whole-list replacement: lists are small, deltas
  /// would be a second truth about what a mirror holds.
  ///
  /// [omadaProjects] names those of the chats' projects with Omada on at the
  /// home device. The default project never is, so a name is enough; a peer
  /// that predates the field sends none, which reads as none on.
  const factory SyncMessage.welcome({
    required List<ChatState> chats,
    @Default(<String>[]) List<String> omadaProjects,
    @Default(<String>[]) List<String> projects,
    @Default(SyncIdentity.protocolVersion) int proto,
  }) = SyncWelcome;

  const factory SyncMessage.chatsChanged({
    required List<ChatState> chats,
    @Default(<String>[]) List<String> omadaProjects,
    @Default(<String>[]) List<String> projects,
  }) = SyncChatsChanged;

  /// Subscribe to one of the peer's chats from record [fromLine] on — the
  /// count of records the asking side already holds. Zero is a fresh open.
  const factory SyncMessage.chatOpen({
    required String chatId,
    @Default(0) int fromLine,
  }) = SyncChatOpen;

  /// The reply to [SyncChatOpen]: the chat's head, and nothing else. The
  /// records follow as [SyncRecordAppend]s — a whole conversation is far past
  /// what one data channel message may carry, and half a megabyte is an
  /// ordinary size for one. What a mirror holds is what it has been sent, so
  /// a resume counts from its own record count and needs no total to compare
  /// against.
  const factory SyncMessage.chatSnapshot({
    required String chatId,
    required ChatState state,
    required ChatMeta meta,
  }) = SyncChatSnapshot;

  /// Records for a subscribed chat, in order: the pages of a snapshot, and
  /// then whatever the turn appends as it happens. A snapshot plus these
  /// rebuilds the log exactly.
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

  // ---- Driving a turn from the other end. -------------------------------

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

  /// [files] went ahead as [SyncResourceChunk]s under their ids. Answered by
  /// a [SyncReply] naming any whose bytes did not arrive.
  const factory SyncMessage.promptSend({
    required String requestId,
    required String chatId,
    required String text,
    @Default(<SyncFile>[]) List<SyncFile> files,
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

  // ---- Editing the conversation. ----------------------------------------

  const factory SyncMessage.editResend({
    required String chatId,
    required String messageId,
    required String text,
  }) = SyncEditResend;

  const factory SyncMessage.regenerate({
    required String chatId,
    required String messageId,
  }) = SyncRegenerate;

  const factory SyncMessage.threadStep({
    required String chatId,
    required String messageId,
    required int step,
  }) = SyncThreadStep;

  const factory SyncMessage.threadDelete({
    required String chatId,
    required String messageId,
  }) = SyncThreadDelete;

  // ---- Writing the chat itself, from any paired device. -----------------
  // Answered by the ordinary state, meta or deletion message, which is what
  // the asking side waits on.

  const factory SyncMessage.stateWrite({
    required String chatId,
    required ChatState state,
    @Default(false) bool reanchor,
  }) = SyncStateWrite;

  const factory SyncMessage.metaWrite({
    required String chatId,
    required ChatMeta meta,
  }) = SyncMetaWrite;

  const factory SyncMessage.retitle({
    required String chatId,
    required String title,
  }) = SyncRetitle;

  const factory SyncMessage.chatDelete({required String chatId}) =
      SyncChatDelete;

  /// Make a chat in [project] and say [text] in it. Answered by a
  /// [SyncReply] carrying its id, after the chat list that names it.
  const factory SyncMessage.chatStart({
    required String requestId,
    String? project,
    required String text,
    @Default(<SyncFile>[]) List<SyncFile> files,
  }) = SyncChatStart;

  /// The answer to a request by its [requestId]: [ok] where it went through,
  /// [chatId] the chat a [SyncChatStart] made, and [missing] the attachments
  /// a prompt named whose bytes did not arrive.
  const factory SyncMessage.reply({
    required String requestId,
    @Default(true) bool ok,
    String? chatId,
    @Default(<String>[]) List<String> missing,
  }) = SyncReply;

  // ---- A project on the home device, read only while it is open. --------

  /// Follow [project]'s settings until [SyncProjectClose]. Null is the home
  /// device's default project.
  const factory SyncMessage.projectOpen({String? project}) = SyncProjectOpen;

  const factory SyncMessage.projectClose({String? project}) = SyncProjectClose;

  /// [project]'s settings and the app settings they inherit from, whole, on
  /// open and on every change to either while followed.
  const factory SyncMessage.projectSnapshot({
    String? project,
    required ProjectSettings settings,
    required AppSettings app,
  }) = SyncProjectSnapshot;

  /// [project]'s skills and agents, after the first snapshot and on every
  /// change to them: [PromptDocument] JSON, paged by size while [more].
  const factory SyncMessage.projectPrompts({
    String? project,
    required List<Map<String, dynamic>> documents,
    @Default(false) bool more,
  }) = SyncProjectPrompts;

  /// Read or change [project]'s memories: [op] is `list`, `search` (by
  /// [text]), `add` ([text]), `pin`, `unpin` or `delete` ([id]). Answered by
  /// [SyncMemories]: what a list or the search reads after it.
  const factory SyncMessage.memoryCall({
    required String requestId,
    String? project,
    required String op,
    String? id,
    String? text,
  }) = SyncMemoryCall;

  /// [MemoryEntry] JSON, paged by size while [more]; [failed] where the call
  /// did not go through.
  const factory SyncMessage.memories({
    required String requestId,
    @Default(<Map<String, dynamic>>[]) List<Map<String, dynamic>> entries,
    @Default(false) bool more,
    @Default(false) bool failed,
  }) = SyncMemories;

  /// The three below are answered by a [SyncReply]; a follower has the
  /// snapshot of what was written ahead of it.
  const factory SyncMessage.projectWrite({
    required String requestId,
    String? project,
    required ProjectSettings settings,
  }) = SyncProjectWrite;

  /// [settings] are the new project's, written with it.
  const factory SyncMessage.projectCreate({
    required String requestId,
    required String name,
    ProjectSettings? settings,
  }) = SyncProjectCreate;

  const factory SyncMessage.projectDelete({
    required String requestId,
    required String name,
  }) = SyncProjectDelete;

  factory SyncMessage.fromJson(Map<String, dynamic> json) =>
      _$SyncMessageFromJson(json);
}

/// An attachment sent with a prompt, its bytes ahead of it under [id].
@freezed
abstract class SyncFile with _$SyncFile {
  const factory SyncFile({
    required String id,
    required String filename,
    required String mimeType,
  }) = _SyncFile;

  factory SyncFile.fromJson(Map<String, dynamic> json) =>
      _$SyncFileFromJson(json);
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
