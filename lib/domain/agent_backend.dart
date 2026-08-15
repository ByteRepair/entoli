import "package:uuid/uuid.dart";

import "../core/config.dart";
import "../domain/models.dart";

/// A brand new chat, with its directories in place.
Future<Chat> newChat(
  AppConfig? config, {
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

/// An attempt failed and is being retried. The turn is still alive, so this is
/// a status, not an outcome — but it is the first sign of trouble.
class RetryEvent extends AgentEvent {
  const RetryEvent({required this.attempt, required this.message});
  final int attempt;
  final String message;
}

class ErrorEvent extends AgentEvent {
  const ErrorEvent(this.message);
  final String message;
}

/// What runs a turn. `MinisweBackend` is the implementation; this exists as a
/// seam so the UI and the repository can be tested without one.
abstract class AgentBackend {
  /// Create a new chat with a fresh workspace and agent session.
  Future<Chat> createChat({String? title, String? model, String? provider});

  /// Send a user prompt; stream events until the turn completes.
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments,
      String? model,
      String? provider,
      bool approveCommands});

  /// Drop the chat's live session so the next prompt starts a clean one,
  /// seeded with [history].
  Future<void> resetSession(String chatId, {List<Message> history = const []});

  /// Release everything this backend holds. Called when the app exits.
  Future<void> shutdown();

  Future<void> abort(String chatId);

  /// How long a turn may produce nothing before the UI gives up on it. Every
  /// failure is reported as it happens, so silence only ever means work — the
  /// budget has to cover the longest command a turn may run.
  Duration get stallTimeout;

  Future<List<ToolApproval>> pendingApprovals(String chatId);

  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response);

  /// Release resources for a chat (keeps on-disk data).
  Future<void> disposeChat(String chatId);

  Future<List<ModelOption>> models();
}