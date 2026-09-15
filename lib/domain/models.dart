import "dart:typed_data";

import "package:freezed_annotation/freezed_annotation.dart";

part "models.freezed.dart";
part "models.g.dart";

@freezed
abstract class ChatState with _$ChatState {
  const factory ChatState({
    required String id,
    required String title,
    required DateTime createdAt,
    required DateTime updatedAt,

    /// Which project's `chats/` this lives in. Null is the default project —
    /// the data directory itself, where every chat was before there were any.
    /// The directory a chat is found in wins over this: a chat moved by hand
    /// is in the project it was moved to.
    String? project,

    /// Whether this chat is pinned. Pinned chats sit under a "Pinned" heading
    /// ahead of the date groups in the sidebar, show a pin in the chat title
    /// bar, and cannot be temporary — pinning clears the TTL anchor and
    /// overrides `meta.tempChatTtl` to off. Set by `ChatRepository.pinChat`,
    /// cleared by `unpinChat`.
    @Default(false) bool pinned,

    /// When this chat's temporary TTL was enabled. Set once when the resolved
    /// TTL becomes non-off, cleared when it goes back to off. Maintained by
    /// `ChatRepository.saveState`, which sees the resolved TTL; the sidebar
    /// and the sweep read [tempTtlExpiresAt] rather than computing from this.
    DateTime? tempTtlSince,

    /// When this chat expires, denormalized as [tempTtlSince] + the resolved
    /// duration. Recomputed on every save so widening the app/project window
    /// extends an existing chat from its original anchor. The sidebar hides a
    /// chat once this is in the past; the background sweep deletes it.
    DateTime? tempTtlExpiresAt,
  }) = _ChatState;

  factory ChatState.fromJson(Map<String, dynamic> json) => _$ChatStateFromJson(json);
}

/// Whether this chat's TTL window has passed. The one place the sidebar
/// filter, the background sweep and the on-open prompt ask it from, so they
/// agree. Null [ChatState.tempTtlExpiresAt] means the chat is not temporary.
extension ChatStateTtl on ChatState {
  bool isExpired({DateTime? now}) {
    final expiresAt = tempTtlExpiresAt;
    return expiresAt != null && !expiresAt.isAfter(now ?? DateTime.now());
  }
}

/// A full chat: state + message tree. Persisted across `state.json` + `conv.jsonl`.
@freezed
abstract class Chat with _$Chat {
  const factory Chat({
    required ChatState state,

    /// The thread being read, which is one path through the tree the log holds.
    @Default([]) List<Message> messages,

    /// For each message in [messages] that has any, the alternatives written
    /// beside it — oldest first, including the one being read. Derived by
    /// `replayTree` rather than persisted, like [unfinished]: the tree is in
    /// the records, and a message on its own says nothing about it.
    @Default({}) Map<String, List<String>> branches,

    /// The last message is a reply whose turn never finished, and so is one to
    /// offer to carry on. Derived from the log by `endsUnfinished` rather than
    /// persisted — the absence of a closing record is the whole of it.
    @Default(false) bool unfinished,

  }) = _Chat;

  factory Chat.fromJson(Map<String, dynamic> json) => _$ChatFromJson(json);
}

/// Where a message sits among the threads written at its point in the
/// conversation. The counter under a message, and what its arrows move between.
extension Threads on Chat {
  /// Every thread written where [messageId] is, oldest first. One entry — the
  /// message itself — where nothing was ever branched there.
  List<String> threadsAt(String messageId) => branches[messageId] ?? [messageId];

  /// Which of [threadsAt] is being read, counting from zero.
  int threadIndex(String messageId) => threadsAt(messageId).indexOf(messageId);

  /// The thread to move to, or null at either end. Deliberately does not wrap:
  /// an arrow that comes back to where it started reads as having done nothing.
  String? threadBeside(String messageId, int step) {
    final to = threadIndex(messageId) + step;
    final threads = threadsAt(messageId);
    return to < 0 || to >= threads.length ? null : threads[to];
  }

  /// Whether replacing [message] should leave it behind as a thread to go back
  /// to. A turn stopped before it said anything is not one: the counter under
  /// the answer would offer a blank page. Anything said after it is worth
  /// keeping even so — the reply stayed empty, but the conversation went on
  /// under it, and that is not something to delete for the sake of a counter.
  /// That second half is also what makes deleting safe: nothing is below a
  /// message this refuses.
  ///
  /// Both askers are writers — [withTurn] for the conversation on screen, the
  /// controller for the record that says the same thing. `replayTree` never
  /// asks, because the record already carries what was decided. So this is not
  /// `TurnEnd.resumable`, which a reader and a writer have to agree on; it is
  /// on [Chat] because a message alone cannot answer the second half.
  ///
  /// It only ever decides about a reply. A prompt always carries a `TextPart`,
  /// empty text and all — see `ChatController._prompt` — so an edit branches
  /// whatever was typed.
  bool worthAThread(Message message) =>
      message.parts.isNotEmpty || messages.lastOrNull?.id != message.id;

  /// What this becomes when a turn opening with [turn] starts: on the end of
  /// the conversation, or — where [replacing] names a message — in place of
  /// that one, which cuts the thread back to it and counts the first new
  /// message among the threads there.
  ///
  /// A [replacing] that is not [worthAThread] is *replaced* rather than kept
  /// beside its replacement, so it leaves no counter behind.
  ///
  /// This is what `replayTree` will make of the records the turn writes, said
  /// here as well so an edit or a regenerate does not cost a reload of the log
  /// to draw. The two have to agree, and what pins that is
  /// `chat_controller_test.dart`'s "what a branch puts on screen is what a
  /// reload reads back", which compares both the messages and the branches.
  Chat withTurn(List<Message> turn, {Message? replacing}) {
    if (replacing == null) {
      return copyWith(messages: [...messages, ...turn], unfinished: false);
    }
    final at = messages.indexWhere((m) => m.id == replacing.id);
    assert(at >= 0, "${replacing.id} is not on the thread being read");
    final kept = messages.take(at).toList();
    final threads = [...threadsAt(replacing.id), turn.first.id];
    if (!worthAThread(replacing)) threads.remove(replacing.id);
    return copyWith(
      messages: [...kept, ...turn],
      branches: {
        // A branch below this one went with the thread it was on.
        for (final message in kept) message.id: ?branches[message.id],
        if (threads.length > 1) turn.first.id: threads,
      },
      unfinished: false,
    );
  }
}

enum MessageRole { system, user, assistant, tool }

/// One message of a conversation. Which thread it is on, and what it was
/// written as an alternative to, are in the log rather than here — see
/// `replayTree`, which is the only thing that can answer either.
@freezed
abstract class Message with _$Message {
  const factory Message({
    required String id,
    required MessageRole role,
    required DateTime createdAt,
    @Default([]) List<MessagePart> parts,
    /// What this message's `/command` and `@agent` references meant when it was
    /// sent, keyed by the reference as written — `/review`, `@researcher`. See
    /// "Commands and agents" in `lib/domain/CLAUDE.md`.
    @Default({}) Map<String, String> documents,

    /// The addressed member who authored this message, as keyed in
    /// [documents]; null is the main agent, unnamed — and every message
    /// written before this existed.
    String? author,

    /// The room's Omada state when this turn was opened, written on the
    /// turn's first message by the controller. What sections the thread
    /// holds derives from these stamps. Null on every message that is not a
    /// turn opener, and on every message written before sections existed.
    bool? omadaOn,
  }) = _Message;

  factory Message.fromJson(Map<String, dynamic> json) => _$MessageFromJson(json);
}

/// Polymorphic part of a message: what the model said, thought, ran, or was
/// handed.
///
/// `responseId` names the provider response a part came out of. A turn is
/// several of them — think, call a tool, think again — and each has to be
/// projected back as one message: a provider handed a reasoning block that
/// outlived the tool call it preceded rejects the turn. Only what a response
/// produces carries one; a result belongs to the call it answers.
@freezed
sealed class MessagePart with _$MessagePart {
  const factory MessagePart.text({
    required String text,
    String? responseId,
  }) = TextPart;

  /// The model thinking out loud. Kept out of [TextPart] because it is not the
  /// reply: the UI files it under a label and a transcript leaves it out.
  /// [durationMs] is null while it is still being written.
  ///
  /// [signature] is Anthropic's and exists only for it: with thinking enabled
  /// it rejects a tool-use turn whose thinking comes back unsigned, so a
  /// conversation replayed out of the log has to hand the token back. Nothing
  /// else reads it — if `AnthropicClient` stops needing one, this field goes
  /// with it.
  const factory MessagePart.reasoning({
    required String text,
    int? durationMs,
    String? signature,
    String? responseId,
  }) = ReasoningPart;
  const factory MessagePart.toolCall({
    required ToolCall toolCall,
    String? responseId,
  }) = ToolCallPart;
  const factory MessagePart.toolResult({required ToolResult result}) = ToolResultPart;

  /// A command the user ran themselves, by starting a message with `!`. Not a
  /// [ToolCallPart]: no model asked for it, and one reading the conversation
  /// back would find itself having called a tool it never chose.
  ///
  /// [command] is here as well as in the prompt above because the projection
  /// words one message at a time and has no prompt beside it to read.
  /// [cwd] is the directory the run's shell was left in, where the shell is
  /// the chat's own persistent one and reports it. The projection turns the
  /// change in it into the note a later turn reads; see "The projection".
  const factory MessagePart.shellRun({
    required String command,
    required int returnCode,
    required String output,
    String? exceptionInfo,
    String? cwd,
    @Default([]) List<String> violations,
  }) = ShellRunPart;
  const factory MessagePart.file({
    required String resource,
    required String filename,
    required String mimeType,
  }) = FilePart;
  const factory MessagePart.error({required String message}) = ErrorPart;

  /// An HTML page the model rendered, saved under the chat's `artifacts/` dir
  /// and viewable in the app. The [artifactId] is the subdir name; [entryFile]
  /// is the filename the viewer opens; [title] is what the label reads. The
  /// HTML lives on disk, not in the log, so a big artifact does not bloat
  /// `conv.jsonl`.
  const factory MessagePart.artifact({
    required String artifactId,
    required String entryFile,
    required String title,
  }) = ArtifactPart;

  /// A skill the model drafted and packaged for the user to install. The
  /// [installId] names the staged `.skill` package under the chat's directory;
  /// [title] is what the card reads. The name, description and body are read
  /// back from the package on the preview page, not carried on the part. The
  /// package lives on disk, not in the log.
  const factory MessagePart.skillInstall({
    required String installId,
    required String title,
  }) = SkillInstallPart;

  factory MessagePart.fromJson(Map<String, dynamic> json) => _$MessagePartFromJson(json);
}

@freezed
abstract class ToolCall with _$ToolCall {
  const factory ToolCall({
    required String id,
    required String name,
    String? argumentsJson,
    String? argumentsText,
  }) = _ToolCall;

  factory ToolCall.fromJson(Map<String, dynamic> json) => _$ToolCallFromJson(json);
}

@freezed
abstract class ToolResult with _$ToolResult {
  /// [cwd] is the directory the chat's shell was left in, where the shell is
  /// the persistent one and reports it — the fact a directory move is, rather
  /// than the wording of it. The projection words the change into a note; see
  /// "The projection".
  const factory ToolResult({
    required String callId,
    required int returnCode,
    required String output,
    String? exceptionInfo,
    String? cwd,
    @Default([]) List<String> violations,
  }) = _ToolResult;

  factory ToolResult.fromJson(Map<String, dynamic> json) => _$ToolResultFromJson(json);
}

/// A file the composer is holding, on its way to the chat's `resources/`. Once
/// saved it is a [FilePart] of the message and the bytes are read back from
/// disk, so this is the one shape that carries them around.
class Attachment {
  const Attachment({
    required this.filename,
    required this.mimeType,
    required this.bytes,
  });

  final String filename;
  final String mimeType;
  final Uint8List bytes;
}

/// What the composer's `+` button can attach. Only the chooser's filter
/// differs — an image is a file narrowed down to.
enum AttachmentKind { image, file }

/// A pending tool-call approval surfaced to the UI.
@freezed
abstract class ToolApproval with _$ToolApproval {
  const factory ToolApproval({
    required String id,
    required String toolName,
    String? argumentsJson,

    String? argumentsText,

    /// The directories a re-prompt banner is agreeing to — what the sandbox
    /// refused while the command ran. Empty for an ordinary banner, where an
    /// "always" answer derives a command rule instead.
    @Default([]) List<String> deniedDirs,
  }) = _ToolApproval;

  factory ToolApproval.fromJson(Map<String, dynamic> json) => _$ToolApprovalFromJson(json);
}

enum ApprovalResponse {
  allow,

  deny,

  /// Allow, and write the rule on the chat's `meta.json` so the same call
  /// runs unasked for the rest of this chat. Read back by the backend as
  /// [allow], the persisted rule being the durable half.
  alwaysAllowChat,

  /// Allow, and write the rule on the project's `project.json`.
  alwaysAllowProject,
}

/// A model the user can pick in settings.
@freezed
abstract class ModelOption with _$ModelOption {
  const factory ModelOption({
    required String providerId,
    required String modelId,
    String? label,
  }) = _ModelOption;

  factory ModelOption.fromJson(Map<String, dynamic> json) => _$ModelOptionFromJson(json);
}

/// A [ModelOption] as it is stored and passed around. The registry keys clients
/// by provider id and two endpoints can offer the same model id, so this is a
/// pair or it is nothing — never one half.
typedef ModelChoice = ({String? providerId, String? modelId});

/// What a message can address, the character that starts one, and the
/// directory the files defining them live in — the app's own are embedded in
/// code (generated from `assets/prompts/` at build time), the user's are under
/// `$AGENT_CHAT_CONFIG/`. A skill's directory holds a `SKILL.md` (and whatever
/// else the skill needs); an agent's holds flat `.md` files.
enum CompletionKind {
  skill("/", "Skills", "skills"),
  agent("@", "Agents", "agents");

  const CompletionKind(this.trigger, this.label, this.folder);
  final String trigger;
  final String label;
  final String folder;
}

/// An entry in the composer's `/` or `@` menu — a skill the backend can load,
/// or an agent a message can address. Built from a `PromptDocument`, never
/// deserialized: the file on disk is the persisted form.
@freezed
abstract class CompletionOption with _$CompletionOption {
  const factory CompletionOption({
    required String name,
    String? description,
    String? argumentHint,
  }) = _CompletionOption;
}

/// Text and files are scattered across parts; almost every caller wants one
/// kind at a time.
extension MessageParts on Message {
  String get plainText => parts.whereType<TextPart>().map((p) => p.text).join("\n");

  bool get hasText => parts.whereType<TextPart>().any((p) => p.text.trim().isNotEmpty);

  Iterable<FilePart> get files => parts.whereType<FilePart>();

  /// Results by the call they answer. They arrive as parts of their own, but
  /// a call and its result are one thing that happened.
  Map<String, ToolResult> get toolResults => {
        for (final part in parts.whereType<ToolResultPart>()) part.result.callId: part.result,
      };
}

extension ChatTitle on String {
  String get orUntitled => isEmpty ? "(untitled)" : this;
}
