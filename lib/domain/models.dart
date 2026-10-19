import "dart:typed_data";

import "package:freezed_annotation/freezed_annotation.dart";

part "models.freezed.dart";
part "models.g.dart";

/// What a permission decision was: run without asking, hold for the user,
/// or refuse outright. The gate's verdict — what a rule records, what the
/// classifier returns, what a banner answer amounts to.
enum PermissionDecision {
  /// Run it without asking.
  allow,

  /// Escalate to the user — emit the approval banner and wait.
  ask,

  /// Refuse it outright, without running or asking.
  deny,
}

/// What decided a call's fate before it ran. Recorded on the call's
/// [ToolResult] as `decidedBy`, so the label and its drawer say not just
/// "allowed" but what allowed it. Null on a result from before the field
/// existed — the UI then says nothing.
enum PermissionSource {
  /// A standing rule matched, at the [PermissionTier] recorded beside it.
  rule,

  /// The classifier model decided, in auto mode.
  classifier,

  /// A human answered the banner.
  human,

  /// The approve mode ran it itself — `never`, including a sub-agent's.
  mode,

  /// A sandbox-denied command, rerun after the human answered.
  rerun,

  /// The command parse vouched for it — every segment provably
  /// non-modifying, or mutations covered by a grant policy — decided before
  /// any rule, model or person was asked.
  parse,
}

/// Which tier carried the decision. A compound command's segments can be
/// covered by several, so the record is the list of the ones that spoke.
enum PermissionTier {
  /// A banner answer, this one call only.
  once,

  /// A rule on the chat's `meta.json`, or an answer persisted there.
  chat,

  /// A rule on the chat's own project's `project.json`.
  project,

  /// A rule on the default project's — what General > Permissions edits,
  /// which every project inherits. Worded "the app's rules" in the UI.
  defaultProject,

  /// A rule granted for the rest of the running turn, by an "always"
  /// banner answer.
  runtime,
}

/// Where an instruction file was reached from — what the turn was reading
/// when it loaded, and so what a label about the read says. Lives in the
/// domain beside the part that records it; `renderInstructions` words the
/// same values into the model's prompt, off the one shared phrase table
/// below.
enum InstructionKind {
  /// At the data dir's root: the user's, for every project.
  global,

  /// At the project workspace root, shared by its chats.
  project,

  /// Reached through an `@path` reference in another instructions file.
  imported,

  /// Found above a file the agent read, mid-turn.
  directory,

  /// Shipped by the app for a project whose turns read no file: the note
  /// stands in for the instruction files.
  bundled,
}

/// What [InstructionKind] reads as, on a label's drawer and in the model's
/// prompt. One table so the two cannot disagree — the `outcomeText` pattern.
String instructionKindPhrase(InstructionKind kind) => switch (kind) {
      InstructionKind.global => "the user's global instructions, for every project",
      InstructionKind.project => "project workspace instructions",
      InstructionKind.imported => "instructions imported by another file",
      InstructionKind.directory => "instructions for this directory",
      InstructionKind.bundled => "the app's own note on this kind of chat",
    };

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

/// One compaction on the thread being read, as the log records it. The
/// summary stands in for everything up to and including the message it names
/// when the conversation is put in front of a model; the user still reads
/// those messages, the divider saying where the summary took over. Derived by
/// `replayTree` from the records rather than persisted as state, like
/// `Chat.branches`: a rewind past the boundary drops the marker the same way
/// it drops the messages under it.
@freezed
sealed class ConversationCompaction with _$ConversationCompaction {
  const factory ConversationCompaction({
    required String upToMessageId,
    required String summary,

    /// The conversation's estimated size with the summary standing in, so the
    /// context page can say what compacting left before the next request
    /// measures it. Null on markers written before it existed.
    int? chatTokens,
  }) = _ConversationCompaction;

  factory ConversationCompaction.fromJson(Map<String, dynamic> json) =>
      _$ConversationCompactionFromJson(json);
}

/// What a reply's last request held, by segment, estimated at four characters
/// a token. [reported] is the provider's count for the whole, where it gave
/// one; the segments are always ours, the split being what no provider says.
@freezed
abstract class ContextUsage with _$ContextUsage {
  const ContextUsage._();

  const factory ContextUsage({
    required int system,
    required int tools,

    /// The "About the user" block, counted apart from the [system] prompt it
    /// sits in.
    required int profile,
    required int chat,
    int? reported,
  }) = _ContextUsage;

  factory ContextUsage.fromJson(Map<String, dynamic> json) =>
      _$ContextUsageFromJson(json);

  int get estimated => system + tools + profile + chat;

  int get total => reported ?? estimated;

  /// [segment] as a share of [total], so the parts sum to the provider's count.
  int share(int segment) =>
      estimated == 0 ? 0 : (segment * total / estimated).round();
}

extension Contexts on Chat {
  /// Each participant's context as the thread being read stands, keyed by
  /// author, null the house: their newest reply that has one, its chat taken
  /// from a compaction that came after it.
  Map<String?, ContextUsage> get contexts {
    final marker = compactions.lastOrNull;
    final boundary = marker?.chatTokens == null
        ? -1
        : messages.indexWhere((m) => m.id == marker!.upToMessageId);
    final out = <String?, ContextUsage>{};
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      final context = m.context;
      if (context == null || out.containsKey(m.author)) continue;
      out[m.author] = i <= boundary
          ? context.copyWith(chat: marker!.chatTokens!, reported: null)
          : context;
    }
    return out;
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

    /// The compaction markers on the thread being read, oldest first — see
    /// [ConversationCompaction]. Derived by `replayTree` from the records, so
    /// a rewind past a boundary drops the marker the same way it drops the
    /// messages under it.
    @Default([]) List<ConversationCompaction> compactions,

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
    /// "Commands and agents" in `lib/domain/AGENTS.md`.
    @Default({}) Map<String, String> documents,

    /// The addressed member who authored this message, as keyed in
    /// [documents]; null is the main agent, unnamed — and every message
    /// written before this existed.
    String? author,

    /// The members the room routed this say to, sigils on as typed, in the
    /// order mentioned — the room's own record of who was being spoken to,
    /// not a re-parse of the text. Empty is the house's mail, and every
    /// message written before the field existed. A reply's is stamped when
    /// it closes `done` (`TurnEndRecord.addressees`): the members its text
    /// names, its own author never among them.
    @Default([]) List<String> addressees,

    /// The room's Omada state when this turn was opened, written on the
    /// turn's first message by the controller. What sections the thread
    /// holds derives from these stamps. Null on every message that is not a
    /// turn opener, and on every message written before sections existed.
    bool? omadaOn,

    /// A reply's context as its last request held it, written on the turn's
    /// close (`TurnEndRecord.context`). Null on a turn that never closed, and
    /// on every reply written before the field existed.
    ContextUsage? context,
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

  /// A permission the turn asked for and the answer it got. Not a
  /// [ToolCallPart]: nothing ran because a model chose it, and a model
  /// reading the conversation back would find itself having asked for what
  /// its own gate asked. What the user is shown of a past turn's gating is
  /// the banner and its answer — this is that, recorded. The toolName and
  /// [ToolApproval.argumentsText] word the banner; [answer] is the response
  /// as pressed. The turn-scoped view state carries the live banner; this
  /// part is what a reload draws instead.
  const factory MessagePart.approval({
    required String approvalId,
    required String toolName,
    String? argumentsText,
    @Default([]) List<String> deniedDirs,
    required String answer,
  }) = ApprovalPart;

  /// The instruction files this turn was the first to read into the model's
  /// context — the up-front `AGENTS.md` load, or a nested one a file read
  /// pulled in. One part per first reach, at most: a later turn re-reading
  /// the same file writes nothing, the claim being decided against what the
  /// history already records. The content itself is not here — it rides the
  /// per-turn system message, rewritten every turn — so this is the record
  /// of the read, drawn as an activity label, and never part of what the
  /// conversation says.
  const factory MessagePart.instructions({
    required List<InstructionRef> files,
  }) = InstructionsPart;

  factory MessagePart.fromJson(Map<String, dynamic> json) => _$MessagePartFromJson(json);
}

@freezed
abstract class InstructionRef with _$InstructionRef {
  const factory InstructionRef({
    required String path,
    required InstructionKind kind,
  }) = _InstructionRef;

  factory InstructionRef.fromJson(Map<String, dynamic> json) =>
      _$InstructionRefFromJson(json);
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
    /// What decided this call's fate before it ran, and the tiers that
    /// spoke — a compound covered from two tiers carries both. Null on a
    /// result from before the field existed, and null where nothing stood
    /// in front of the call: the mode's default posture of asking is not a
    /// decision to record, the banner it raises being its own record.
    PermissionSource? decidedBy,
    @Default([]) List<PermissionTier> decidedTier,
    /// What the decider said — the verdict, recorded rather than inferred
    /// from the exit code, which says whether the command ran but not why
    /// it was held.
    PermissionDecision? decided,
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

    /// Whether this is the sandbox's re-prompt: an offer to rerun a call
    /// unconfined, whose "always" is [deniedDirs] and never a command rule.
    @Default(false) bool rerun,
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
  alwaysAllowProject;

  /// Whether the answer grants the call at all, however it persists — the
  /// three are the banner's yes forms, [deny] its only no.
  bool get isAllow =>
      this == allow || this == alwaysAllowChat || this == alwaysAllowProject;
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
/// `$ENTOLI_CONFIG/`. A skill's directory holds a `SKILL.md` (and whatever
/// else the skill needs); an agent's holds flat `.md` files.
enum CompletionKind {
  skill("/", "Skills", "skills"),
  agent("@", "Agents", "agents");

  const CompletionKind(this.trigger, this.label, this.folder);
  final String trigger;
  final String label;

  /// The directory the files defining them live in — and, being one string
  /// for both, the marketplace site's section path too
  /// (`byterepair.github.io/entoli-marketplace/<folder>/index.json`). The site
  /// is laid out to match; renaming either half must rename both.
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
