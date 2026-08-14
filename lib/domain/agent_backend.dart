import "../domain/models.dart";

/// Streamed events from an agent turn. The UI renders these as they arrive.
sealed class AgentEvent {
  const AgentEvent();
}

class TextDelta extends AgentEvent {
  const TextDelta(this.text);
  final String text;
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

/// Platform-agnostic agent backend. Each platform provides an implementation:
/// `OpencodeBackend` (Linux desktop), `MinisweChaquopyBackend` (Android),
/// `MiniswePyodideBackend` (Web).
abstract class AgentBackend {
  /// Create a new chat with a fresh workspace and backend session.
  Future<Chat> createChat({String? title, String? model, String? provider});

  /// Send a user prompt; stream events until the turn completes.
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments, String? model, String? provider});

  /// Drop the chat's live session so the next prompt starts a clean one,
  /// optionally seeded with [transcript]. Used when resending a message.
  Future<void> resetSession(String chatId, {String? transcript});

  /// Abort the running turn.
  Future<void> abort(String chatId);

  /// Pending tool approvals for a chat.
  Future<List<ToolApproval>> pendingApprovals(String chatId);

  /// Respond to a tool approval.
  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response);

  /// Release resources for a chat (keeps on-disk data).
  Future<void> disposeChat(String chatId);

  /// Models available to the current backend.
  Future<List<ModelOption>> availableModels();

  /// List models without an active chat. Starts a temporary server if
  /// needed. Returns empty if unsupported.
  Future<List<ModelOption>> listModelsStandalone();

  /// Kind of this backend.
  BackendKind get kind;
}