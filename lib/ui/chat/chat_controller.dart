import "dart:async";
import "dart:math" as math;

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../../domain/agent_backend.dart";
import "../../domain/ask.dart";
import "../../domain/chat_log.dart";
import "../../domain/chat_repository.dart";
import "../../domain/turn_recorder.dart";
import "../../domain/models.dart";
import "../../providers.dart";

/// Per-chat state container exposed to the UI.
class ChatViewState {
  ChatViewState({
    this.chat,
    this.isRunning = false,
    this.approvals = const [],
    this.questions = const [],
    this.runningSubAgents = const [],
    this.retry,
    this.status,
    this.unfinishedNotice,
  });
  final Chat? chat;
  final bool isRunning;
  final List<ToolApproval> approvals;

  /// What the agent is waiting to be told. Turn-scoped like [approvals]: the
  /// call and the answers are what the conversation keeps.
  final List<AskRequest> questions;

  /// Sub-agents spawned by `task` calls that are still running. Turn-scoped
  /// view state like [approvals]: the call/result pair is what persists, and
  /// these exist only to drive the activity strip.
  final List<SubAgentStartEvent> runningSubAgents;

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

  ChatViewState copyWith({
    Chat? chat,
    bool? isRunning,
    List<ToolApproval>? approvals,
    List<AskRequest>? questions,
    List<SubAgentStartEvent>? runningSubAgents,
    String? retry,
    bool clearRetry = false,
    String? status,
    bool clearStatus = false,
    String? unfinishedNotice,
    bool clearUnfinishedNotice = false,
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
      );
}

/// What a page needs of whatever is driving its turn. [ChatController] for a
/// chat on this device, `MirrorChatController` for one whose home device is a
/// paired peer — the widgets between them are the same either way, and only
/// where the work happens differs.
abstract interface class TurnDriver {
  Future<void> send(String text, {List<Attachment> attachments});
  Future<void> resume();
  Future<void> abort();
  Future<void> respondApproval(String approvalId, ApprovalResponse r);
  Future<void> answerQuestions(String requestId, List<String?> answers);
}

/// Drives a single chat: loads from store, sends prompts, accumulates streamed
/// events into messages, and appends them to the chat's log as they arrive.
class ChatController extends Notifier<ChatViewState> implements TurnDriver {
  ChatController(this.chatId);

  final String chatId;
  final _uuid = const Uuid();
  StreamSubscription<AgentEvent>? _sub;

  /// Everything that turns this turn's events into the reply's parts and the
  /// records that persist them. Shared with `SubAgentRunner`, which keeps one
  /// per `task` call — see [TurnRecorder].
  late final TurnRecorder _recorder;

  /// This turn is being stopped rather than ended — see [interrupt]. Cleared
  /// where a turn opens, beside the recorder's own `outcome`, so it cannot
  /// reach the next one.
  bool _interrupted = false;

  /// Bumped by [abort] and [interrupt] so a pending automatic retry cannot
  /// fire after the user pressed stop: the round waits out its backoff
  /// holding nothing, and the generation is what tells it the turn it was
  /// carrying on was ended behind it.
  int _retryGen = 0;

  /// Completes with the turn's [TurnEnd] (or null if interrupted) when the
  /// current turn finishes. A caller that starts a turn through [send] or
  /// [resume] and needs to know when it is done — the reminder runner, a voice
  /// handover — awaits this. Null when no turn is running.
  Completer<TurnEnd?>? _turnDone;
  Future<TurnEnd?>? get turnDone => _turnDone?.future;

  @override
  ChatViewState build() {
    _recorder = TurnRecorder(
      append: (records) => ref.read(chatRepositoryProvider).append(chatId, records),
      onParts: _writeReply,
    );
    // The provider is not auto-disposed: clear a controller that outlived its page, or its id re-opens the deleted chat from memory.
    final deletionSub = ref.read(chatRepositoryProvider).changes.listen((event) {
      if (event is Deleted && event.chatId == chatId) state = ChatViewState();
    });
    ref.onDispose(() {
      _sub?.cancel();
      deletionSub.cancel();
      _recorder.dispose();
    });
    _ready = _load();
    return ChatViewState();
  }

  /// The first read of the chat off disk. **Anything that drives a turn waits
  /// on it**, because a controller is built the moment something asks for it
  /// and driven in the same breath — `createChat` sends the first message,
  /// `RemoteTurnDriver` hands over a peer's — and a turn started before this
  /// lands finds no chat and silently does nothing.
  late Future<void> _ready;

  /// The reply being written. It is always the last message of a running turn.
  Message? get _reply {
    final messages = state.chat?.messages;
    return messages == null || messages.isEmpty ? null : messages.last;
  }

  /// The reply's text, for a caller that needs what the turn said without
  /// watching the event stream — the reminder driver, after [turnDone].
  String get replyText => _reply?.plainText ?? "";

  void _writeReply(List<MessagePart> parts) {
    final chat = state.chat;
    final reply = _reply;
    if (chat == null || reply == null) return;
    final messages = List<Message>.from(chat.messages);
    messages[messages.length - 1] = reply.copyWith(parts: parts);
    state = state.copyWith(chat: chat.copyWith(messages: messages));
  }

  /// Take a state written elsewhere — the sidebar pinning this chat — in place.
  /// Reloading instead would dispose a running turn. Nothing to do where the
  /// chat is not loaded yet: it reads the same write off disk.
  void applyState(ChatState written) {
    final chat = state.chat;
    if (chat == null) return;
    state = state.copyWith(chat: chat.copyWith(state: written));
  }

  /// Retitle in place, for the same reason.
  void applyTitle(String title) {
    final chat = state.chat;
    if (chat == null) return;
    applyState(chat.state.copyWith(title: title));
  }

  /// Name the chat after what started it, unless it is headless — a reminder's
  /// chat is already named. Nothing waits on this: it is a model call of its
  /// own, and the turn it belongs to is already under way.
  Future<void> _maybeNameChat(String prompt) async {
    final repo = ref.read(chatRepositoryProvider);
    if ((await repo.loadMeta(chatId)).headless == true) return;
    final title = await repo.suggestTitle(prompt);
    final chat = state.chat;
    if (title == null || chat == null || !ref.mounted) return;
    applyTitle(title);
    await repo.retitle(chatId, title);
    if (!ref.mounted) return;
    ref.invalidate(chatListProvider);
  }

  Future<void> _load() async {
    try {
      final chat = await ref.read(chatRepositoryProvider).openChat(chatId);
      if (ref.mounted) state = state.copyWith(chat: chat);
    } catch (e) {
      // Deleted under us — swept for its TTL, or removed on a paired device.
      // Left unsaid the page keeps a spinner up with nothing behind it.
      logFailure("chat", "could not open $chatId", e);
    }
  }

  /// The composer's own path: what it is holding becomes files under the chat
  /// before anything else, since from here on a prompt is its parts.
  @override
  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
    await _ready;
    if (state.chat == null || state.isRunning) return;
    final repo = ref.read(chatRepositoryProvider);
    await _prompt(text, files: await repo.saveAttachments(chatId, attachments));
  }

  /// Say [text] and run the turn it starts. [files] are already under the
  /// chat's `resources/`. [replacing] makes it another thread beside a prompt
  /// already in the conversation — an edit — rather than the next thing said.
  Future<void> _prompt(String text,
      {List<MessagePart> files = const [], Message? replacing}) async {
    final repo = ref.read(chatRepositoryProvider);
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final at =
        replacing == null ? chat.messages.length : chat.messages.indexOf(replacing);
    if (at < 0) return;

    final userMsg =
        repo.composeUserPrompt(text, project: chat.state.project, files: files);
    await _turn(
      chat: chat,
      prompt: userMsg,
      history: chat.messages.take(at).toList(),
      opening: [userMsg, _newReply()],
      replacing: replacing,
    );
  }

  /// Open a turn: put the messages it starts with in the conversation and in
  /// the log, then hand the prompt to the backend.
  ///
  /// [opening] is what the turn writes — the prompt and its empty reply, or the
  /// reply alone where the prompt is already there. [history] is the
  /// conversation the model is answering, which does not include the prompt:
  /// `sendPrompt` adds that itself. [replacing] is the message [opening] is an
  /// alternative to, and null when this is simply the next thing said.
  Future<void> _turn({
    required Chat chat,
    required Message prompt,
    required List<Message> history,
    required List<Message> opening,
    Message? replacing,
  }) async {
    final repo = ref.read(chatRepositoryProvider);
    final updated = chat
        .withTurn(opening, replacing: replacing)
        .copyWith(state: chat.state.copyWith(updatedAt: DateTime.now()));

    final isFirst = chat.messages.isEmpty;
    state = state.copyWith(chat: updated, isRunning: true, clearRetry: true, clearStatus: true);
    // The prompt and the empty reply go down before the turn starts, so a chat
    // killed before the model says anything still shows what was asked. What
    // comes back carries the TTL anchor the save resolved, and is kept.
    applyState(await repo.saveState(updated.state));
    _interrupted = false;
    _retryable = false;
    _errorLine = "";
    _round = 0;
    _turnDone = Completer<TurnEnd?>();
    _recorder.open(opening.last.id);
    await _recorder.write(recordsOf(opening,
        siblingOf: replacing?.id,
        replacing: replacing != null && !chat.worthAThread(replacing)));
    // Only the first message names the chat, and not a headless one — the
    // reminder already named it. The list is not refreshed here: the chat was
    // written, and listed, when it was created — and refreshing re-reads every
    // chat off disk to draw the row it already has.
    if (isFirst) unawaited(_maybeNameChat(prompt.plainText));

    _listen(repo.sendPrompt(chatId, prompt,
        history: history, replaces: replacing != null));
  }

  Message _newReply() => Message(
        id: _uuid.v4(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        parts: const [],
      );

  /// Carry on the turn the chat was cut off in. What this produces goes on the
  /// end of the reply that is already there, closed by a second [TurnEndRecord]
  /// when it finishes.
  @override
  Future<void> resume() async {
    await _ready;
    if (state.isRunning) return;
    final chat = state.chat;
    if (chat == null || !chat.unfinished) return;
    await _startResume();
  }

  /// The body of [resume] without its guards, so the automatic retry rounds
  /// take the same path the user's Continue button does. The chat is checked
  /// where the caller can still read its answer; the reply is re-read here
  /// because a round sees a chat the previous round just wrote to.
  Future<void> _startResume() async {
    final chat = state.chat;
    final reply = chat!.messages.last;

    state = state.copyWith(isRunning: true, clearRetry: true, clearStatus: true);
    _interrupted = false;
    // Kept open across the round: a caller awaiting [turnDone] gets one
    // completion, at the true end, not one per attempt.
    _turnDone ??= Completer<TurnEnd?>();
    _recorder.open(reply.id, existing: reply.parts);

    _listen(ref.read(chatRepositoryProvider)
        .resumeTurn(chatId, history: chat.messages));
  }

  void _listen(Stream<AgentEvent> stream) {
    _sub?.cancel();
    _sub = stream.listen(_onEvent, onDone: _finishTurn, onError: _onError);
  }

  /// The user message that produced [messageId] — itself when it is one,
  /// otherwise the closest one above it.
  Message? _promptFor(Chat chat, String messageId) {
    final from = chat.messages.indexWhere((m) => m.id == messageId);
    if (from < 0) return null;
    final at = chat.messages.lastIndexWhere((m) => m.role == MessageRole.user, from);
    return at < 0 ? null : chat.messages[at];
  }

  /// The reply [messageId] names — itself when it is one, otherwise the first
  /// one under it. Null where the turn has none, which is a prompt whose only
  /// reply has been deleted.
  Message? _replyFor(Chat chat, String messageId) {
    final from = chat.messages.indexWhere((m) => m.id == messageId);
    if (from < 0) return null;
    final at = chat.messages.indexWhere((m) => m.role == MessageRole.assistant, from);
    return at < 0 ? null : chat.messages[at];
  }

  /// Resend a message with new text, as another thread beside it. The file
  /// parts come across as they are: the resources are already under this chat,
  /// and branching leaves the message they belong to where it is.
  Future<void> editAndResend(String messageId, String text) async {
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final prompt = _promptFor(chat, messageId);
    if (prompt == null) return;
    await _prompt(text, files: prompt.files.toList(), replacing: prompt);
  }

  /// Run the turn again, as another thread beside the reply already there.
  ///
  /// The prompt is not written a second time: it is the branch point, so the
  /// counter lands under the reply — which is the message the arrows move
  /// between. Works from either side of the exchange, and carries on the end
  /// where the reply it would have branched from has been deleted.
  Future<void> regenerate(String messageId) async {
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final prompt = _promptFor(chat, messageId);
    if (prompt == null) return;
    await _turn(
      chat: chat,
      prompt: prompt,
      history: chat.messages.take(chat.messages.indexOf(prompt)).toList(),
      opening: [_newReply()],
      replacing: _replyFor(chat, messageId),
    );
  }

  /// Read the thread beside the one [messageId] is on. [step] is -1 or 1 — the
  /// arrows under the message.
  Future<void> stepThread(String messageId, int step) async {
    final chat = _rethreadable;
    final to = chat?.threadBeside(messageId, step);
    if (chat == null || to == null) return;
    await _rethread((repo) => repo.selectThread(chat, to));
  }

  /// Delete the thread [messageId] heads, and everything below it.
  Future<void> deleteThread(String messageId) async {
    final chat = _rethreadable;
    if (chat == null) return;
    await _rethread((repo) => repo.deleteThread(chat, messageId));
  }

  /// The conversation a thread change can be worked out from, or null where
  /// there is none to make. An earlier change still in flight is one of those:
  /// it is about to replace the conversation this one would be computed from,
  /// so a held-down arrow would issue a reload per frame against state that no
  /// longer holds.
  Chat? get _rethreadable => state.isRunning || _rethreading ? null : state.chat;
  bool _rethreading = false;

  Future<void> _rethread(Future<Chat> Function(ChatRepository repo) change) async {
    _rethreading = true;
    try {
      final now = await change(ref.read(chatRepositoryProvider));
      if (ref.mounted) state = state.copyWith(chat: now);
    } finally {
      _rethreading = false;
    }
  }

  void _onEvent(AgentEvent event) {
    if (_reply == null) return;

    _recorder.handle(event);
    switch (event) {
      // What the recorder already turned into parts. Listed rather than
      // defaulted, so a new kind of event has to be decided about here too.
      case ResponseStart():
      case TextDelta():
      case ReasoningDelta():
      case ReasoningEnd():
      case ToolCallEvent():
      case ToolResultEvent():
      case ShellRunEvent():
      case ArtifactEvent():
      case SkillInstallEvent():
        break;
      case ErrorEvent(:final message, :final retryable):
        // Whether the round can carry the turn on from this, and the first
        // line for the retry row and the failure notification. Both are
        // turn-scoped view state: the error part is what the conversation
        // keeps, and neither field outlives the turn.
        _retryable = retryable;
        final lineAt = message.indexOf("\n");
        _errorLine = lineAt < 0 ? message : message.substring(0, lineAt);
        break;
      case StepLimitEvent():
      case InfoEvent():
        break;
      case ApprovalRequestEvent(:final approval):
        state = state.copyWith(approvals: [...state.approvals, approval]);
      case QuestionRequestEvent(:final request):
        state = state.copyWith(questions: [...state.questions, request]);
      case SubAgentStartEvent():
        state = state.copyWith(runningSubAgents: [...state.runningSubAgents, event]);
      case SubAgentEndEvent(:final id):
        state = state.copyWith(
            runningSubAgents:
                state.runningSubAgents.where((s) => s.id != id).toList());
      case RetryEvent(:final attempt, :final message):
        state = state.copyWith(retry: "Attempt $attempt failed: $message");
      case StatusEvent(:final label):
        state = label == null
            ? state.copyWith(clearStatus: true)
            : state.copyWith(status: label);
      case DoneEvent(:final aborted):
        if (aborted) _recorder.outcome ??= TurnEnd.aborted;
        _finishTurn();
    }
  }

  /// The turn is over when it has been written, not when the last event
  /// arrives. Writing is asynchronous — a browser's filesystem cannot be
  /// anything else — so returning before the queue drains would report a
  /// finished turn whose last records are still in flight, and closing the app
  /// in that window would lose them. A write that fails still has to clear
  /// [isRunning], or the composer stays disabled with nothing running.
  ///
  /// The terminal record is the point of this: a log whose last message has no
  /// [TurnEndRecord] was being written when the process died, and that absence
  /// is the only thing that can tell a reload the difference.
  Future<void> _finishTurn() async {
    _sub?.cancel();
    _sub = null;
    // Null is a turn that was interrupted rather than ended — the log has no
    // closing record, and `?? true` below is the same thing its reader makes
    // of one. See "Carrying on an interrupted turn".
    final TurnEnd? reason;
    if (_interrupted) {
      await _recorder.interrupt();
      reason = null;
    } else {
      reason = await _recorder.close();
    }
    // A retryable failure is a blip the turn is carried on from, not an
    // outcome to report: the round waits out its backoff and re-enters the
    // same resume the user's Continue button takes. The wait holds nothing —
    // the user pressing stop has to reach it first, which is what the
    // generation is for. The turn's completer stays open across rounds, so a
    // caller awaiting [turnDone] — the reminder runner, voice — gets one
    // completion, at the true end.
    if (reason == TurnEnd.error && _retryable && _roundsLeft > 0) {
      final gen = _retryGen;
      final round = _round;
      _round++;
      final wait = Duration(seconds: math.pow(2, round).clamp(1, 30).toInt());
      if (!ref.mounted) return;
      state = state.copyWith(
        retry: "Retrying ($_round/$_roundsTotal) — $_errorLine",
        approvals: const [],
        questions: const [],
        runningSubAgents: const [],
      );
      await Future<void>.delayed(wait);
      if (_retryGen != gen || !ref.mounted) return;
      // A stopped turn has no chat to carry on; a deleted one the same.
      if (state.chat == null || _interrupted) return;
      await _startResume();
      return;
    }
    if (!ref.mounted) return;
    final done = _turnDone;
    _turnDone = null;
    // Nothing is left to answer once the turn is over: the backend has already
    // answered its own outstanding questions with nothing, so a banner or a
    // panel still on screen would send its reply into the void.
    state = state.copyWith(
      // What a reload would now make of the log, so a turn that gave up is
      // offered straight away rather than only once the chat is opened again.
      chat: state.chat?.copyWith(unfinished: reason?.resumable ?? true),
      isRunning: false,
      approvals: const [],
      questions: const [],
      runningSubAgents: const [],
      clearRetry: true,
      clearStatus: true,
      unfinishedNotice: reason == TurnEnd.stepLimit
          ? "Step limit reached"
          : null,
    );
    done?.complete(reason);
    await _notifyFailure(reason);
  }

  /// The failure the turn last reported, for the retry row and the
  /// notification — turn-scoped like every other view state, never persisted.
  bool _retryable = false;
  String _errorLine = "";
  int _round = 0;

  /// What this turn is allowed: the setting, resolved at the round the same
  /// way the approve mode is, so an edit reaches the next failure rather than
  /// the next launch.
  int get _roundsTotal => ref.read(appSettingsProvider).turnRetries;
  int get _roundsLeft => math.max(0, _roundsTotal - _round);

  /// The notification. A failure the user cannot see is a failure the app has
  /// to say — the turn is over, the chat is on disk, and the tap opens it.
  /// Posted only where all three hold: the app is not visible (the user is
  /// somewhere else entirely, not on another chat), the chat is not headless
  /// (reminder completions are the scheduler's, and a second would be a
  /// double), and the platform can post at all (a no-op elsewhere, so the
  /// check is really about not promising what nothing delivers).
  Future<void> _notifyFailure(TurnEnd? reason) async {
    if (reason != TurnEnd.error) return;
    if (!ref.read(appHiddenProvider)) return;
    final repo = ref.read(chatRepositoryProvider);
    if ((await repo.loadMeta(chatId)).headless == true) return;
    final alarms = ref.read(reminderAlarmsProvider);
    final title = state.chat?.state.title ?? "Chat failed";
    await alarms.notify(
      title: title,
      body: _errorLine.isEmpty ? "The turn failed." : _errorLine,
      chatId: chatId,
      channel: "turns",
    );
  }

  void _onError(Object e) {
    _retryable = false;
    _recorder.handle(ErrorEvent(e.toString()));
    _finishTurn();
  }

  /// Set before the abort is awaited, though `DoneEvent.aborted` would say the
  /// same: killing the turn closes the stream, and a backend that closed it
  /// without the event would let `onDone` reach [_finishTurn] first and record
  /// the turn as having finished.
  @override
  Future<void> abort() async {
    _retryGen++;
    _recorder.outcome = TurnEnd.aborted;
    await ref.read(chatRepositoryProvider).abort(chatId);
    await _finishTurn();
  }

  /// Stop a turn without ending it: the agent is cancelled and the log is left
  /// **open**, so the chat offers to carry it on. See "Carrying on an
  /// interrupted turn" for why this is not [abort].
  ///
  /// Set before the agent is cancelled, the way [abort] sets its outcome:
  /// cancelling closes the stream, so [_finishTurn] can run from the `onDone`
  /// rather than from the line below, and it has to make the same decision
  /// whichever gets there first.
  Future<void> interrupt() async {
    if (!state.isRunning) return;
    _retryGen++;
    _interrupted = true;
    await ref.read(chatRepositoryProvider).abort(chatId);
    await _finishTurn();
  }

  @override
  Future<void> respondApproval(String approvalId, ApprovalResponse r) async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.respondApproval(chatId, approvalId, r);
    state = state.copyWith(
        approvals: state.approvals.where((a) => a.id != approvalId).toList());
  }

  /// Answer a request the panel was showing. One entry per question it held,
  /// null where nothing was picked.
  @override
  Future<void> answerQuestions(String requestId, List<String?> answers) async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.respondQuestions(chatId, requestId, answers);
    state = state.copyWith(
        questions: state.questions.where((r) => r.id != requestId).toList());
  }
}

final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatViewState, String>(ChatController.new);

/// Stop whatever turns are running the way the app going away stops them:
/// **interrupted rather than aborted**. See "Carrying on an interrupted turn"
/// for why, and for what this does not reach.
Future<void> interruptLiveTurns(ProviderContainer container) async {
  await Future.wait([
    for (final id in container.read(agentBackendProvider).runningTurns.value)
      if (container.exists(chatControllerProvider(id)))
        container.read(chatControllerProvider(id).notifier).interrupt(),
  ]);
}