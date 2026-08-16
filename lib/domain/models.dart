import "dart:typed_data";

import "package:freezed_annotation/freezed_annotation.dart";

part "models.freezed.dart";
part "models.g.dart";

/// Metadata for a chat, persisted to `state.json`.
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
  }) = _ChatState;

  factory ChatState.fromJson(Map<String, dynamic> json) => _$ChatStateFromJson(json);
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
    final threads = threadsAt(messageId);
    final to = threads.indexOf(messageId) + step;
    return to < 0 || to >= threads.length ? null : threads[to];
  }

  /// What this becomes when [opening] is written as an alternative to
  /// [siblingOf]: the conversation cut back to where it branches, the new
  /// messages on the end of it, and the first of them counted among the threads
  /// it has joined.
  ///
  /// This is what `replayTree` will make of the records a branch appends, said
  /// here as well so an edit or a regenerate does not cost a reload of the log
  /// to draw. The two have to agree; the one thing keeping them honest is that
  /// both put a new thread last and read it.
  Chat withBranch(String siblingOf, List<Message> opening) {
    final at = messages.indexWhere((m) => m.id == siblingOf);
    if (at < 0 || opening.isEmpty) return this;
    final above = {for (final message in messages.take(at)) message.id};
    return copyWith(
      messages: [...messages.take(at), ...opening],
      branches: {
        // A branch below this one went with the thread it was on.
        for (final threads in branches.entries)
          if (above.contains(threads.key)) threads.key: threads.value,
        opening.first.id: [...threadsAt(siblingOf), opening.first.id],
      },
      unfinished: false,
    );
  }
}

enum MessageRole { system, user, assistant, tool }

/// A node in the conversation tree. Linear in v1; tree-structured later.
@freezed
abstract class Message with _$Message {
  const factory Message({
    required String id,
    required MessageRole role,
    required DateTime createdAt,
    @Default([]) List<MessagePart> parts,
    String? parentId,
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
  const factory MessagePart.file({
    required String resource,
    required String filename,
    required String mimeType,
  }) = FilePart;
  const factory MessagePart.error({required String message}) = ErrorPart;

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
  const factory ToolResult({
    required String callId,
    required int returnCode,
    required String output,
    String? exceptionInfo,
  }) = _ToolResult;

  factory ToolResult.fromJson(Map<String, dynamic> json) => _$ToolResultFromJson(json);
}

/// A file the user attached to a message. The agent is sent [bytes];
/// [resource] is the name they were saved under in the chat's `resources/`,
/// null until they have been.
class Attachment {
  const Attachment({
    required this.filename,
    required this.mimeType,
    required this.bytes,
    this.resource,
  });

  final String filename;
  final String mimeType;
  final Uint8List bytes;
  final String? resource;
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
  }) = _ToolApproval;

  factory ToolApproval.fromJson(Map<String, dynamic> json) => _$ToolApprovalFromJson(json);
}

enum ApprovalResponse { allow, deny }

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

/// What a message can address, the character that starts one, and the
/// directory the files defining them live in — under `assets/prompts/` when
/// they ship with the app, under `$AGENT_CHAT_CONFIG/` when the user adds one.
enum CompletionKind {
  command("/", "Commands", "commands"),
  agent("@", "Agents", "agents");

  const CompletionKind(this.trigger, this.label, this.folder);
  final String trigger;
  final String label;
  final String folder;
}

/// An entry in the composer's `/` or `@` menu — a command the backend can run,
/// or an agent a message can address. Built from a `PromptDocument`, never
/// deserialized: the file on disk is the persisted form.
@freezed
abstract class CompletionOption with _$CompletionOption {
  const factory CompletionOption({
    required String name,
    String? description,
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
