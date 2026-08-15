import "dart:typed_data";

import "package:freezed_annotation/freezed_annotation.dart";

part "models.freezed.dart";
part "models.g.dart";

/// Which agent runtime backs this chat.
enum BackendKind { opencode, miniswe }

/// Metadata for a chat, persisted to `state.json`.
@freezed
abstract class ChatState with _$ChatState {
  const factory ChatState({
    required String id,
    required String title,
    required DateTime createdAt,
    required DateTime updatedAt,
    required BackendKind backend,
    String? model,
    String? provider,
  }) = _ChatState;

  factory ChatState.fromJson(Map<String, dynamic> json) => _$ChatStateFromJson(json);
}

/// A full chat: state + message tree. Persisted across `state.json` + `conv.json`.
@freezed
abstract class Chat with _$Chat {
  const factory Chat({
    required ChatState state,
    @Default([]) List<Message> messages,
  }) = _Chat;

  factory Chat.fromJson(Map<String, dynamic> json) => _$ChatFromJson(json);
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

/// Polymorphic part of a message. Mirrors OpenCode's Part union plus
/// mini-swe-agent's action/observation shapes, unified.
@freezed
sealed class MessagePart with _$MessagePart {
  const factory MessagePart.text({required String text}) = TextPart;
  const factory MessagePart.toolCall({required ToolCall toolCall}) = ToolCallPart;
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

/// What a message can address, and the character that starts one.
enum CompletionKind {
  command("/", "Commands"),
  agent("@", "Agents");

  const CompletionKind(this.trigger, this.label);
  final String trigger;
  final String label;
}

/// An entry in the composer's `/` or `@` menu — a command the backend can run,
/// or an agent a message can address.
@freezed
abstract class CompletionOption with _$CompletionOption {
  const factory CompletionOption({
    required String name,
    String? description,
  }) = _CompletionOption;

  factory CompletionOption.fromJson(Map<String, dynamic> json) =>
      _$CompletionOptionFromJson(json);
}

/// Text and files are scattered across parts; almost every caller wants one
/// kind at a time.
extension MessageParts on Message {
  String get plainText => parts.whereType<TextPart>().map((p) => p.text).join("\n");

  bool get hasText => parts.whereType<TextPart>().any((p) => p.text.trim().isNotEmpty);

  Iterable<FilePart> get files => parts.whereType<FilePart>();
}

extension ChatTitle on String {
  String get orUntitled => isEmpty ? "(untitled)" : this;
}
