import "package:uuid/uuid.dart";

import "../core/config.dart";
import "../domain/models.dart";

/// A brand new chat, with its directories in place. Every backend builds one
/// the same way; only where the work runs differs.
Future<Chat> newChat(
  AppConfig? config, {
  required BackendKind kind,
  String? title,
  String? model,
  String? provider,
}) async {
  final chatId = const Uuid().v4();
  config?.ensureChatDirs(chatId);
  final now = DateTime.now();
  return Chat(
    state: ChatState(
      id: chatId,
      title: title ?? "New chat",
      createdAt: now,
      updatedAt: now,
      backend: kind,
      model: model,
      provider: provider,
    ),
  );
}

/// Streamed events from an agent turn. The UI renders these as they arrive.
sealed class AgentEvent {
  const AgentEvent();
}

class TextDelta extends AgentEvent {
  const TextDelta(this.text);
  final String text;
}

/// A chunk of the model's thinking. Apart from [TextDelta] because it is not
/// the reply — it belongs behind the turn's "Thought for..." label.
class ReasoningDelta extends AgentEvent {
  const ReasoningDelta(this.text);
  final String text;
}

/// The thinking block is closed. [text] is the whole of it: a provider that
/// streams no deltas still sends it here, so it is what the block ends up
/// holding.
class ReasoningEnd extends AgentEvent {
  const ReasoningEnd({this.text, this.duration});
  final String? text;
  final Duration? duration;
}

class ToolCallEvent extends AgentEvent {
  const ToolCallEvent(this.call);
  final ToolCall call;
}

class ToolResultEvent extends AgentEvent {
  const ToolResultEvent(this.result);
  final ToolResult result;
}

class ApprovalRequestEvent extends AgentEvent {
  const ApprovalRequestEvent(this.approval);
  final ToolApproval approval;
}

class DoneEvent extends AgentEvent {
  const DoneEvent();
}

/// An attempt failed and the backend is retrying. The turn is still alive, so
/// this is a status, not an outcome — but it is the first sign of trouble,
/// arriving long before the retries are exhausted.
class RetryEvent extends AgentEvent {
  const RetryEvent({required this.attempt, required this.message});
  final int attempt;
  final String message;
}

class ErrorEvent extends AgentEvent {
  const ErrorEvent(this.message);
  final String message;
}

/// Platform-agnostic agent backend. Implementations: `OpencodeBackend`,
/// `MinisweBackend`, and `RoutingBackend` over both.
abstract class AgentBackend {
  /// Create a new chat with a fresh workspace and backend session.
  Future<Chat> createChat({String? title, String? model, String? provider});

  /// Send a user prompt; stream events until the turn completes.
  ///
  /// [approveCommands] is the chat's answer to "ask before running anything".
  /// A backend that decides for itself — opencode's permission rules are its
  /// own — ignores it.
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments,
      String? model,
      String? provider,
      bool approveCommands});

  /// Drop the chat's live session so the next prompt starts a clean one,
  /// seeded with [history] — how that conversation is worded for the agent is
  /// the backend's business.
  Future<void> resetSession(String chatId, {List<Message> history = const []});

  /// Release every process and connection this backend owns. Called when the
  /// app exits; without it spawned servers outlive it.
  Future<void> shutdown();

  Future<void> abort(String chatId);

  /// Whether this backend asks before running a command, and so whether
  /// `approveCommands` means anything to it. Declared rather than documented
  /// so the UI can hide a control that would do nothing.
  bool honoursApprovals(String chatId);

  /// How long a turn may produce nothing before the UI gives up on it. The
  /// backend's to declare, because only it knows what silence means: one that
  /// hides a failure behind its own retries has to be waited out, one that
  /// runs a build has a good reason to say nothing for a while.
  Duration stallTimeout(String chatId);

  Future<List<ToolApproval>> pendingApprovals(String chatId);

  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response);

  /// Release resources for a chat (keeps on-disk data).
  Future<void> disposeChat(String chatId);


  Future<List<ModelOption>> models();

  BackendKind get kind;
}