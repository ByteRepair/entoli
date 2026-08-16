import "../domain/ask.dart";
import "../domain/models.dart";
import "../domain/permission.dart";
import "../domain/profile.dart";

/// Streamed events from an agent turn. The UI renders these as they arrive.
sealed class AgentEvent {
  const AgentEvent();
}

/// The model is about to answer. A turn is several responses — think, call a
/// tool, look at the result, think again — and every part produced from here
/// until the next one belongs to this one. See [MessagePart] for why they have
/// to be kept together.
class ResponseStart extends AgentEvent {
  const ResponseStart(this.id);
  final String id;
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
  const ReasoningEnd({this.text, this.duration, this.signature});
  final String? text;
  final Duration? duration;

  /// Anthropic's signature for the block, where the provider sent one. See
  /// [ReasoningPart.signature] for why it is kept.
  final String? signature;
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

/// The agent has put questions to the user and is waiting on them. The composer
/// gives way to them until they are answered.
class QuestionRequestEvent extends AgentEvent {
  const QuestionRequestEvent(this.request);
  final AskRequest request;
}

class DoneEvent extends AgentEvent {
  const DoneEvent();
}

/// A sub-agent started running a delegated `task` call. Turn-scoped view
/// state like [RetryEvent]: the call/result pair is what persists in
/// `conv.jsonl`, and this exists only to drive the sub-agent activity strip.
class SubAgentStartEvent extends AgentEvent {
  const SubAgentStartEvent({required this.id, required this.agent, required this.prompt});
  final String id;
  final String agent;
  final String prompt;
}

/// A sub-agent finished. Pairs with [SubAgentStartEvent] by [id].
class SubAgentEndEvent extends AgentEvent {
  const SubAgentEndEvent({required this.id, this.failed = false});
  final String id;
  final bool failed;
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

/// A non-error notice the turn wants the UI to show — auto mode pausing, for
/// instance. Turn-scoped like [RetryEvent]: it is view state, not a message
/// part, so it is not persisted.
class InfoEvent extends AgentEvent {
  const InfoEvent(this.message);
  final String message;
}

/// What runs a turn, and the app's one route to a provider. `MinisweBackend`
/// is the implementation; this exists as a seam so the UI and the repository
/// can be tested without one.
abstract class AgentBackend {
  /// A chat with an id and nothing else: its directories and its session are
  /// made when it is first used, so one that is never used costs nothing.
  Future<Chat> createChat({String? title});

  /// One question, answered in one call to [model]: no tools, no session,
  /// nothing kept. Null when the provider is not configured or says nothing —
  /// the caller wants a convenience, and there is no turn to report a failure
  /// on.
  Future<String?> ask(String prompt, {required String model, required String provider});

  /// Send a user prompt; stream events until the turn completes. [project] is
  /// which project's files the turn works in — null is the default one.
  /// [classifierProvider]/[classifierModel] name the model that classifies
  /// commands in auto mode; null means auto mode falls back to asking.
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments,
      String? model,
      String? provider,
      String? project,
      ApproveMode approveMode = ApproveMode.ask,
      String? classifierProvider,
      String? classifierModel,
      Profile? profile});

  /// Drop the chat's live session so the next prompt starts a clean one,
  /// seeded with [history].
  Future<void> resetSession(String chatId, {List<Message> history = const []});

  /// Seed the chat's session with [history] if it does not have one yet. A
  /// session lives in memory for as long as the app does, so a chat opened
  /// after a restart has none — and would otherwise be answered by a model
  /// that had never seen a word of it.
  Future<void> ensureSession(String chatId, List<Message> history);

  /// Release everything this backend holds. Called when the app exits.
  Future<void> shutdown();

  Future<void> abort(String chatId);

  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response);

  /// Answer the questions of [requestId]: one entry per question, in the order
  /// they were asked, null where the user answered nothing.
  Future<void> respondQuestions(String chatId, String requestId, List<String?> answers);

  /// Release resources for a chat (keeps on-disk data).
  Future<void> disposeChat(String chatId);

  Future<List<ModelOption>> models();
}