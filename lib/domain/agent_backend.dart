import "dart:async";

import "package:flutter/foundation.dart" show ValueListenable;

import "../domain/ask.dart";
import "../domain/builtin_project.dart";
import "../domain/chat_log.dart";
import "../domain/models.dart";
import "../domain/permission.dart";
import "../domain/profile.dart";
import "../domain/tone.dart";

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

/// Instruction files were read into the model's context for the first time in
/// this conversation — the turn's up-front `AGENTS.md` load, or a nested file
/// a `read` pulled in. Persisted as an [InstructionsPart] rather than
/// turn-scoped view state: the read is a fact about the conversation, and a
/// reloaded chat redraws the label it makes. Emitted only for files the
/// history does not already record, so one conversation labels a file once.
class InstructionsReadEvent extends AgentEvent {
  const InstructionsReadEvent(this.files);
  final List<InstructionRef> files;
}

/// A command the user ran themselves finished — the whole of a `!` turn, which
/// never reaches a model. Carries the part rather than the command and its
/// outcome separately, since the two are one thing that happened and the
/// recorder has nothing of its own to add to them.
class ShellRunEvent extends AgentEvent {
  const ShellRunEvent(this.run);
  final ShellRunPart run;
}

/// What a running command has printed, as it prints it. Turn-scoped view state
/// like [StatusEvent]: the call/result pair is what `conv.jsonl` keeps, and the
/// final output is what that result carries — nothing here is persisted, and a
/// reloaded chat has no trace of it. The text is the tail of what has printed,
/// not the whole, and whitespace-only tails are not worth reporting.
///
/// [callId] is the `bash` call the output belongs to, null where the command
/// is the user's own `!` turn. Nothing routes on it today — one watched run
/// per chat, the block trailing on the waiting message — but the callback the
/// agent is handed knows it, and a second watched run would need it.
class ShellOutputEvent extends AgentEvent {
  const ShellOutputEvent({this.callId, required this.text});
  final String? callId;
  final String text;
}

/// What a request held, once its reply is in. The newest of a turn is the one
/// its close writes; see [Message.context].
class ContextEvent extends AgentEvent {
  const ContextEvent(this.usage);
  final ContextUsage usage;
}

/// An HTML artifact was rendered and saved. Persisted as a [MessagePart] rather
/// than turn-scoped view state: the artifact is durable, and a reloaded chat
/// has to redraw the label and re-open it. The tool call/result pair that
/// produced it is what the conversation keeps, and this is the one extra part
/// that carries the artifact identity.
class ArtifactEvent extends AgentEvent {
  const ArtifactEvent({required this.artifactId, required this.entryFile, required this.title});
  final String artifactId;
  final String entryFile;
  final String title;
}

/// A skill was drafted in the workspace and packaged for the user to install.
/// Persisted as a [MessagePart] like [ArtifactEvent], so a reloaded chat redraws
/// the install card. The `.skill` package is staged under the chat's directory,
/// so it is deleted with the chat.
class SkillInstallEvent extends AgentEvent {
  const SkillInstallEvent({
    required this.installId,
    required this.title,
  });
  final String installId;
  final String title;
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
  const DoneEvent({this.aborted = false});

  /// The turn was cancelled rather than run out. It rides on the event so that
  /// every route to [AgentBackend.abort] records the same thing — the caller is
  /// no longer the only one who knows, which it was while the composer's stop
  /// button was the only route.
  final bool aborted;
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

/// What the turn is doing right now, for the row the spinner is on. Null means
/// it is no longer worth saying — the reply has started, and the caret says the
/// rest.
///
/// Turn-scoped view state like [RetryEvent]: nothing here is persisted, and a
/// conversation read back off disk has no trace of it. It exists because a
/// spinner on its own cannot be told apart from a hang, and on a model running
/// on the device that wait is minutes rather than seconds.
///
/// [label] is already worded for the reader ("Reading the prompt · 43%"): what
/// is worth saying differs per provider and per tool, and the loop is the only
/// thing that knows which it is waiting on.
class StatusEvent extends AgentEvent {
  const StatusEvent(this.label);

  final String? label;
}

/// An attempt failed and is being retried. The turn is still alive, so this is
/// a status, not an outcome — but it is the first sign of trouble.
class RetryEvent extends AgentEvent {
  const RetryEvent({required this.attempt, required this.message});
  final int attempt;
  final String message;
}

class ErrorEvent extends AgentEvent {
  const ErrorEvent(this.message, {this.retryable = false});
  final String message;

  /// Whether carrying the turn on could plausibly succeed — a connection that
  /// dropped, a provider that hiccuped — as opposed to one nothing retries
  /// out of: a rejected key, a bad request, no model selected. What the
  /// controller's automatic retry rounds ask before re-entering [resume].
  final bool retryable;
}

/// The agent ran out of steps without finishing. Not an [ErrorEvent]: the turn
/// gave up because it hit the step limit, not because something broke, so no
/// [ErrorPart] is added to the message. The turn still ends as
/// [TurnEnd.stepLimit], which is resumable — the Continue bar offers to carry
/// on.
class StepLimitEvent extends AgentEvent {
  const StepLimitEvent(this.limit);
  final int limit;
}

/// A non-error notice the turn wants the UI to show — auto mode pausing, for
/// instance. Turn-scoped like [RetryEvent]: it is view state, not a message
/// part, so it is not persisted.
class InfoEvent extends AgentEvent {
  const InfoEvent(this.message);
  final String message;
}

/// What a turn may read and remember, resolved once by `ChatRepository` from
/// the app's gates over which project's store answers. [off] is the value
/// while the subsystem is closed, which is the shipped default: a turn then
/// carries no store and the agent never touches a memory directory. The
/// AGENTS.md files a turn reads are not here: they are read whether or not
/// the subsystem runs.
class MemorySettings {
  /// Whether `@path` references inside an AGENTS.md are expanded into extra
  /// files.
  final bool imports;

  /// Whether reading a file pulls in the AGENTS.md of a subdirectory that has
  /// one.
  final bool nested;

  /// The glob patterns a file's path must not name for an AGENTS.md of its to
  /// be read; empty reads everything.
  final List<String> excludes;

  /// Whether the auto-memory subsystem runs at all.
  final bool autoMemory;

  /// Whether relevant memories are recalled into each turn. A sub-gate of
  /// [autoMemory], on by default.
  final bool recall;

  /// Whether a background model writes memories from a turn after it ends.
  /// A sub-gate of [autoMemory], on by default, inert beside it until [bgModel]
  /// is picked.
  final bool extract;

  /// Whether the agent is offered the memory tools. A sub-gate of [autoMemory],
  /// on by default.
  final bool agentTool;

  /// The effective store, or null when [autoMemory] is off. Which project's
  /// it is — the chat's own or the default's — was resolved before this.
  final String? memoryDir;

  /// The background model that writes memories (extraction, consolidation).
  /// Both halves or neither; null is the feature inert until one is picked.
  final String? bgModel;
  final String? bgProvider;

  const MemorySettings({
    this.imports = true,
    this.nested = true,
    this.excludes = const [],
    this.autoMemory = false,
    this.recall = true,
    this.extract = true,
    this.agentTool = true,
    this.memoryDir,
    this.bgModel,
    this.bgProvider,
  });

  static const off = MemorySettings();
}

/// What a background write to the memories says after the turn that earned
/// it — the "kept a note" line. The turn's own event stream is closed by then,
/// so this is the half of it the stream cannot carry.
class MemoryNote {
  const MemoryNote(this.chatId, this.text);

  final String chatId;
  final String text;
}

/// The one-shot side of the backend: the notes are added as they land and a
/// page listens for the ones its chat is about.
class MemoryNotes {
  final StreamController<MemoryNote> _controller =
      StreamController<MemoryNote>.broadcast();

  Stream<MemoryNote> get notes => _controller.stream;

  void add(MemoryNote note) {
    if (!_controller.isClosed) _controller.add(note);
  }

  Future<void> close() => _controller.close();
}

/// Everything a turn runs under, resolved once by `ChatRepository` from the
/// chat's `meta.json` over the app's `settings.json`. One value because every
/// way of starting a turn takes all of it, and a forwarding site that drops one
/// field is silent.
class TurnSettings {
  /// What this turn reads and remembers.
  final MemorySettings memory;

  /// Only ever a matched pair: the registry keys clients by provider id.
  final String? model;
  final String? provider;

  /// Which project's files the turn works in. Null is the default one.
  final String? project;

  final ApproveMode approveMode;

  /// The model that classifies commands in auto mode. Null means auto mode
  /// falls back to asking.
  final String? classifierProvider;
  final String? classifierModel;

  final Profile? profile;

  /// How this turn's replies are worded. The project's answer over the app's;
  /// [Tone.none] adds nothing to the prompt.
  final Tone tone;

  /// Whether this turn numbers the web pages it drew on and lists them at the
  /// end of the reply. The project's answer over the app's.
  final bool citations;

  /// Whether the project's workspace is shared between its chats. When false,
  /// the chat's own workspace is also the `HOME` of its commands, a `project:`
  /// path resolves inside it, and the prompt says nothing of a shared one.
  final bool sharedWorkspace;

  /// What this turn is not offered. The project's takesaways, plus `ask` and
  /// `task` on a turn nobody is watching: an `ask_user` parks it on a
  /// completer nobody will complete — there is no timeout behind that wait
  /// anywhere — and a `task` fan-out can do the same through a sub-agent.
  final Set<AgentCapability> disabled;

  /// The instruction text the app ships for this turn's project, where its
  /// spec has one. Where set it is the turn's instructions in full: no
  /// AGENTS.md file is read, and the nested walk on a file read is off.
  final String? bundledInstructions;

  /// Where [bundledInstructions] is set, whether the user's instruction files
  /// are also read on top of the bundled note. False keeps the note as the
  /// whole instructions; true reads the global and project AGENTS.md after it,
  /// so the user's rules win on conflict. Has no effect where there is no
  /// bundled note — a user's project reads its files regardless.
  final bool includesUserInstructions;

  /// The project's own command variables, layered over the app-level ones by
  /// the shell. Empty where the project sets none; the app-level ones are the
  /// shell's to read on each command, for the reason they are settings.
  final Map<String, String> environment;

  /// The member this turn is answered by, where the project runs Omada and
  /// the message addressed exactly one: the named agent runs the turn under
  /// its own prompt and session, and its reply is the one on the record. Null
  /// is the main agent — the house — answering as it always has.
  final String? omadaMember;

  /// Whether Omada runs in this turn's project at all: the room is in force
  /// whatever the say was addressed. The roster tool's gate, beside
  /// [omadaMember] — that one says who answers, this says the room exists at
  /// all. A say in the room that names a member who has since left the
  /// library still answers through the house, so the room fact and the
  /// member fact stay separate.
  final bool omada;

  /// How many model calls this turn may make before it stops. The app's own
  /// answer for the level that resolved the turn — a project's own, else the
  /// app default, else the backend's. The backend's [BuiltinOptions.stepLimit]
  /// is the floor this can only name a value for, not widen.
  final int? turnMaxSteps;

  /// The turn's standing permission rules, merged chat first, then project,
  /// then app — consulted before the classifier and the banner in every mode.
  final List<PermissionRule> permissions;

  /// Directories this turn's sandboxed commands may additionally write to,
  /// beside the workspace: the rules' own writes plus the project's
  /// writableDirs, composed by the repository.
  final List<String> writableDirs;

  /// Whether a command the sandbox denied writes to is offered back as an
  /// approval. Null means the app default decides.
  final bool? sandboxReprompt;

  const TurnSettings({
    this.memory = MemorySettings.off,
    this.model,
    this.provider,
    this.project,
    this.approveMode = ApproveMode.ask,
    this.classifierProvider,
    this.classifierModel,
    this.profile,
    this.sharedWorkspace = true,
    this.disabled = const {},
    this.bundledInstructions,
    this.includesUserInstructions = false,
    this.environment = const {},
    this.omadaMember,
    this.omada = false,
    this.turnMaxSteps,
    this.tone = Tone.none,
    this.citations = false,
    this.permissions = const [],
    this.writableDirs = const [],
    this.sandboxReprompt,
  });
}

/// What runs a turn, and the app's one route to a provider. `BuiltinBackend`
/// is the implementation; this exists as a seam so the UI and the repository
/// can be tested without one.
abstract class AgentBackend {
  /// A chat with an id and nothing else: its directories and its session are
  /// made when it is first used, so one that is never used costs nothing.
  Future<Chat> createChat({String? title});

  /// The chats with a turn running, as it changes: a chat is in it from
  /// [sendPrompt] or [resumeTurn] until that turn's event stream has closed,
  /// which is later than the agent stopping — the caller is still writing the
  /// turn's last records. Ids rather than a count, because its readers act on
  /// each turn rather than on how many there are, and they do not all act the
  /// same way: `TurnKeepAlive` aborts, `interruptLiveTurns` interrupts.
  ValueListenable<Set<String>> get runningTurns;

  /// What the background memory writes land as: a note per chat, after the
  /// turn that earned it. A backend with no memory writes simply never adds
  /// one, and a page that is not interested never listens.
  Stream<MemoryNote> get memoryNotes;

  /// What the chat's model last reported a request cost, in context tokens —
  /// the auto-compact threshold's input. Null where nothing has reported:
  /// no turn yet, a provider that says nothing, or the chat gone from the
  /// backend. The newest completion is the newest request's fact, which is
  /// the one that measures the session as it stands.
  int? usageFor(String chatId) => null;

  /// The window that same request stood in, where the registry named one —
  /// written where [usageFor] is written, so the threshold answers both
  /// halves of itself from the backend with no `meta.json` read on the
  /// settle path. Null is the app-wide guess's business at the caller.
  int? contextWindowFor(String chatId) => null;

  /// One question, answered in one call: no tools, no session, nothing kept.
  /// A model of null resolves to the provider's light default — the title
  /// model is set as a provider without naming one. Null when the provider is
  /// not configured or says nothing — the caller wants a convenience, and
  /// there is no turn to report a failure on.
  Future<String?> ask(String prompt, {required String? model, required String? provider});

  /// Summarize [history] so the model can carry on from less of it. One call,
  /// no tools, no session — [ask] with the conversation in front of it.
  ///
  /// [compactions] say where the conversation is already summarized; the last
  /// marker's summary is what the new one merges into, so re-compacting never
  /// loses what the previous one kept. [instructions] are the user's own focus
  /// for the summary, from `/compact <instructions>`; null is the plain one.
  ///
  /// Returns the marker's shape — boundary and summary — or null when
  /// nothing answered: a provider that is not configured, a turn already
  /// running, a summarizer that failed. The caller wants a marker to append,
  /// and there is no turn to report a failure on; [logFailure] has said why.
  Future<ConversationCompaction?> compact(
    String chatId, {
    required List<Message> history,
    required List<ConversationCompaction> compactions,
    required TurnSettings settings,
    required String? instructions,
  });

  /// Send a user prompt; stream events until the turn completes.
  ///
  /// [history] is what was said before this prompt. It travels with the prompt
  /// rather than being handed over first: a session lives in memory for as long
  /// as the app does, so a chat opened after a restart has none, and a separate
  /// call to fill one is a call a caller can forget — leaving a model that has
  /// seen nothing of the chat to answer it fluently. Read only where the
  /// session is empty.
  ///
  /// [compactions] say where [history] is summarized. They ride beside it
  /// rather than in it, for the same reason: a marker is not a message, and
  /// folding one into the list would put words in the conversation nobody
  /// said. The projection applies the newest whose boundary the history holds.
  ///
  /// [prompt] is the message being logged for this turn, not the text of it —
  /// what the model is shown of a user turn is the whole message, attachments
  /// named rather than passed. See "The projection" in `lib/domain/AGENTS.md`.
  Stream<AgentEvent> sendPrompt(String chatId, Message prompt,
      {List<Message> history,
      List<ConversationCompaction> compactions,
      TurnSettings settings});

  /// Carry on the turn [history] ends in. No prompt, because there is no new
  /// thing to say: the model is handed back what it had already done. Unlike
  /// [sendPrompt] this rebuilds the session from [history] whether or not one
  /// is already held.
  Stream<AgentEvent> resumeTurn(String chatId,
      {List<Message> history,
      List<ConversationCompaction> compactions,
      TurnSettings settings});

  /// Drop the chat's live session so the next prompt starts a clean one,
  /// seeded with [history]. [compactions] say where the conversation is
  /// summarized: the rebuild puts the summary where the log put it.
  Future<void> resetSession(String chatId,
      {List<Message> history = const [],
      List<ConversationCompaction> compactions = const []});

  /// Release everything this backend holds. Called when the app exits.
  Future<void> shutdown();

  Future<void> abort(String chatId);

  Future<void> respondApproval(
      String chatId, String approvalId, ApprovalResponse response);

  /// Answer the questions of [requestId]: one entry per question, in the order
  /// they were asked, null where the user answered nothing.
  Future<void> respondQuestions(String chatId, String requestId, List<String?> answers);

  /// Release resources for a chat (keeps on-disk data).
  Future<void> disposeChat(String chatId);

  /// End the chat's persistent shell in [project]'s workspace, where the
  /// shell runs one: the chat is leaving that project, and its shell is
  /// standing in the directory that moves out from under it. The chat's
  /// session and running turn are kept — a move is not a delete.
  void closeChatShell(String chatId, {required String? project});

  Future<List<ModelOption>> models();
}