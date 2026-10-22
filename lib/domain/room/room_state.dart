import "../agent_backend.dart";
import "../ask.dart";
import "../models.dart";

/// Per-chat state container exposed to the UI.
class ChatViewState {
  ChatViewState({
    this.chat,
    this.isRunning = false,
    this.approvals = const {},
    this.questions = const {},
    this.runningSubAgents = const {},
    this.retry,
    this.status,
    this.unfinishedNotice,
    this.shellOutput = const {},
  });
  final Chat? chat;
  final bool isRunning;

  /// What the turn is waiting to be allowed, keyed by the reply that asked
  /// for it — each turn's banner answers its own turn, and a room with two
  /// running shows both.
  final Map<String, List<ToolApproval>> approvals;

  /// What the agent is waiting to be told. Turn-scoped like [approvals]: the
  /// call and the answers are what the conversation keeps.
  final Map<String, List<AskRequest>> questions;

  /// Sub-agents spawned by `task` calls that are still running — delegated
  /// participants at work, shown as room activity. Turn-scoped view state like
  /// [approvals]: the call/result pair is what persists, and these exist only
  /// to drive the activity strip. Keyed by the reply that fanned them out.
  final Map<String, List<SubAgentStartEvent>> runningSubAgents;

  /// Set while the backend is retrying a failed attempt. Transient: it belongs
  /// to the running turn, not to the conversation, so it is never persisted.
  final String? retry;

  /// What the turn is doing, for the row the spinner is on. Transient like
  /// [retry], and null once the reply has started — from there the caret is
  /// what says the turn is alive.
  final String? status;

  /// A notice for the [ResumeBar] when the turn ended resumable — "Step limit
  /// reached" for a step limit, null otherwise. Turn-scoped: not persisted, so
  /// a reload shows the default "Unfinished turn" text.
  final String? unfinishedNotice;

  /// The tail of what a running command has printed, keyed by the reply it
  /// belongs to — a message landing after that reply must not take it over.
  /// Transient like [retry]: the call/result pair is what the conversation
  /// keeps, so the block is gone the moment the pair completes.
  final Map<String, String> shellOutput;

  /// Who may speak now — see [RoomPhase], whose facts "The room's phase is
  /// one answer" in `lib/ui/chat/AGENTS.md` owns.
  RoomPhase get roomPhase => questions.values.any((q) => q.isNotEmpty)
      ? RoomPhase.waitingOnYou
      : isRunning
          ? RoomPhase.agentSpeaking
          : RoomPhase.open;

  ChatViewState copyWith({
    Chat? chat,
    bool? isRunning,
    Map<String, List<ToolApproval>>? approvals,
    Map<String, List<AskRequest>>? questions,
    Map<String, List<SubAgentStartEvent>>? runningSubAgents,
    String? retry,
    bool clearRetry = false,
    String? status,
    bool clearStatus = false,
    String? unfinishedNotice,
    bool clearUnfinishedNotice = false,
    Map<String, String>? shellOutput,
  }) =>
      ChatViewState(
        chat: chat ?? this.chat,
        isRunning: isRunning ?? this.isRunning,
        approvals: approvals ?? this.approvals,
        questions: questions ?? this.questions,
        runningSubAgents: runningSubAgents ?? this.runningSubAgents,
        retry: clearRetry ? null : (retry ?? this.retry),
        status: clearStatus ? null : (status ?? this.status),
        unfinishedNotice: clearUnfinishedNotice
            ? null
            : (unfinishedNotice ?? this.unfinishedNotice),
        shellOutput: shellOutput ?? this.shellOutput,
      );
}

/// Who may speak in the room — see [ChatViewState.roomPhase].
enum RoomPhase {
  /// Nothing is running; the composer is the user's.
  open,

  /// A turn is running and has not asked anything: the main agent is
  /// speaking, the composer shows Stop.
  agentSpeaking,

  /// A turn is waiting on the user — the composer's place is taken by the
  /// question panel.
  waitingOnYou,
}
