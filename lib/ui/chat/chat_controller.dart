import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../../domain/agent_backend.dart";
import "../../domain/ask.dart";
import "../../domain/chat_log.dart";
import "../../domain/chat_repository.dart";
import "../../domain/reminder_alarms.dart";
import "../../domain/turn_recorder.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart"
    show authorFrom, nameOf, singleAgentMention;
import "../../domain/shell.dart" show shellBypassCommand;
import "../../data/builtin/templates.dart" show passWord;
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
    this.shellOutput,
  });
  final Chat? chat;
  final bool isRunning;
  final List<ToolApproval> approvals;

  /// What the agent is waiting to be told. Turn-scoped like [approvals]: the
  /// call and the answers are what the conversation keeps.
  final List<AskRequest> questions;

  /// Sub-agents spawned by `task` calls that are still running — delegated
  /// participants at work, shown as room activity. Turn-scoped view state like
  /// [approvals]: the call/result pair is what persists, and these exist only
  /// to drive the activity strip.
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

  /// The tail of what a running command has printed. Transient like
  /// [retry]: the call/result pair is what the conversation keeps, so the
  /// block is gone the moment the pair completes.
  final String? shellOutput;

  /// Who may speak now — see [RoomPhase], whose facts "The room's phase is
  /// one answer" in `lib/ui/chat/CLAUDE.md` owns.
  RoomPhase get roomPhase => questions.isNotEmpty
      ? RoomPhase.waitingOnYou
      : isRunning
          ? RoomPhase.agentSpeaking
          : RoomPhase.open;

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
    String? shellOutput,
    bool clearShellOutput = false,
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
        shellOutput:
            clearShellOutput ? null : (shellOutput ?? this.shellOutput),
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

  /// The live turns, keyed by the reply each writes. One today; the table is
  /// what lets a second turn run beside the first without its recorder, its
  /// retry state or its interrupt reaching across — see [_RunningTurn].
  final Map<String, _RunningTurn> _turns = {};

  /// Every recorder's writes funnel through one queue, so two turns appending
  /// to the same log cannot interleave lines. One turn serialises through its
  /// own recorder already; the funnel is for the room with more than one.
  Future<void>? _appendQueue;

  /// Appends [records] to this chat's log behind every append before it.
  Future<void> _append(List<ChatRecord> records) {
    final queued = _appendQueue;
    final repo = ref.read(chatRepositoryProvider);
    return _appendQueue =
        (queued == null ? Future<void>.sync(() => repo.append(chatId, records)) : queued.then((_) => repo.append(chatId, records)))
            .catchError((Object _) {});
  }

  /// Open a turn: its recorder, its completer, and its place in the table.
  /// [existing] is what the log already holds of the reply — nothing for a new
  /// turn, its parts so far for one being carried on.
  _RunningTurn _openTurnEntry(String replyId,
      {List<MessagePart> existing = const []}) {
    final turn = _RunningTurn(
      replyId: replyId,
      done: Completer<TurnEnd?>(),
      append: _append,
    );
    turn.onParts = _writeReply;
    turn.recorder.open(replyId, existing: existing);
    _turns[replyId] = turn;
    return turn;
  }

  /// Completes with the running turn's [TurnEnd] (or null if interrupted)
  /// when it finishes. A caller that starts a turn through [send] or [resume]
  /// and needs to know when it is done — the reminder runner, a voice
  /// handover — awaits this. Null when no single turn is running.
  Future<TurnEnd?>? get turnDone =>
      _turns.length == 1 ? _turns.values.first.done.future : null;

  @override
  ChatViewState build() {
    // The provider is not auto-disposed: clear a controller that outlived its page, or its id re-opens the deleted chat from memory.
    final deletionSub = ref.read(chatRepositoryProvider).changes.listen((event) {
      if (event is Deleted && event.chatId == chatId) state = ChatViewState();
    });
    ref.onDispose(() {
      for (final turn in _turns.values) {
        turn.sub?.cancel();
        turn.recorder.dispose();
      }
      deletionSub.cancel();
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

  /// The single running turn, where exactly one is — every path that drives,
  /// stops or watches a turn speaks about it, and a room with two running has
  /// to name which.
  _RunningTurn? get _liveTurn =>
      _turns.length == 1 ? _turns.values.first : null;

  String get replyText => _reply?.plainText ?? "";

  /// Fold [parts] into the message [turn] is writing, by id rather than by
  /// position: the last message is the running turn's only while it is the
  /// only turn, and a second reply growing beside it is not patched by
  /// coincidence.
  void _writeReply(_RunningTurn turn, List<MessagePart> parts) {
    final chat = state.chat;
    if (chat == null) return;
    final at = chat.messages.indexWhere((m) => m.id == turn.replyId);
    if (at < 0) return;
    final messages = List<Message>.from(chat.messages);
    messages[at] = messages[at].copyWith(parts: parts);
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
  ///
  /// Guards after each await, before any read of [state]: an invalidated
  /// controller (a chat moved while a turn was starting) keeps its in-flight
  /// futures, and a read through the disposed notifier throws.
  Future<void> _maybeNameChat(String prompt) async {
    if (!ref.mounted) return;
    final repo = ref.read(chatRepositoryProvider);
    if (await _isHeadless()) return;
    final title = await repo.suggestTitle(prompt);
    if (!ref.mounted) return;
    final chat = state.chat;
    if (title == null || chat == null) return;
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
  /// before anything else, since from here on a prompt is its parts. Said
  /// while a turn runs, it is appended to the log as it stands and dispatched
  /// when the room settles — the log is the queue.
  @override
  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
    await _ready;
    if (state.chat == null) return;
    final repo = ref.read(chatRepositoryProvider);
    final files = await repo.saveAttachments(chatId, attachments);
    if (state.isRunning) {
      await _sayLater(text, files);
      return;
    }
    await _prompt(text, files: files);
  }

  /// What was said while a turn ran and is still unsaid. The messages are on
  /// the log already — written as they were said — and this is what is left
  /// to say.
  final List<({String text, List<MessagePart> files})> _said = [];

  Future<void> _sayLater(String text, List<MessagePart> files) async {
    final userMsg = ref.read(chatRepositoryProvider).composeUserPrompt(text,
        project: state.chat?.state.project, files: files);
    final chat = state.chat!;
    await ref
        .read(chatRepositoryProvider)
        .append(chatId, recordsOf([userMsg]));
    final messages = List<Message>.from(chat.messages)..add(userMsg);
    state = state.copyWith(
        chat: chat.copyWith(
            messages: messages,
            state: chat.state.copyWith(updatedAt: DateTime.now())));
    _said.add((text: text, files: files));
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
    await openTurn(
      chat: chat,
      prompt: userMsg,
      history: chat.messages.take(at).toList(),
      opening: [userMsg, _newReply(author: authorFor(chat, userMsg))],
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
  Future<void> openTurn({
    required Chat chat,
    required Message prompt,
    required List<Message> history,
    required List<Message> opening,
    Message? replacing,
  }) async {
    final repo = ref.read(chatRepositoryProvider);
    // The room's mode at this turn, stamped on the turn's opener: the page
    // derives sections from these stamps, a separator above an opener that
    // flips from the last one. The implicit off a chat starts in is not a
    // section — nothing separates the first exchange from a chat that never
    // heard of Omada — so the first flip is the on-flip; the off-flip is
    // what bounds an on-section for the label rule.
    final omada = ref.read(omadaOnProvider(chat.state.project));
    final openingWithMode = [
      opening.first.copyWith(omadaOn: omada),
      ...opening.sublist(1),
    ];
    final updated = chat
        .withTurn(openingWithMode, replacing: replacing)
        .copyWith(state: chat.state.copyWith(updatedAt: DateTime.now()));

    final isFirst = chat.messages.isEmpty;
    state = state.copyWith(chat: updated, isRunning: true, clearRetry: true, clearStatus: true);
    // The prompt and the empty reply go down before the turn starts, so a chat
    // killed before the model says anything still shows what was asked. What
    // comes back carries the TTL anchor the save resolved, and is kept.
    applyState(await repo.saveState(updated.state));
    final turn = _openTurnEntry(opening.last.id);
    turn.retryable = false;
    turn.errorLine = "";
    turn.round = 0;
    // The user speaking resets the round — a fresh send, an edit, a
    // regenerate; each is them saying the next thing, not an agent handing
    // off. The cap is about agents handing off to each other without end.
    if (prompt.role == MessageRole.user) _generation = 0;
    await turn.recorder.write(recordsOf(openingWithMode,
        siblingOf: replacing?.id,
        replacing: replacing != null && !chat.worthAThread(replacing)));
    // Only the first message names the chat, and not a headless one — the
    // reminder already named it. The list is not refreshed here: the chat was
    // written, and listed, when it was created — and refreshing re-reads every
    // chat off disk to draw the row it already has.
    if (isFirst) unawaited(_maybeNameChat(prompt.plainText));

    // Invalidated mid-turn — a chat moved while one was starting. The move
    // aborted whatever was running, so this turn never starts; there is
    // nothing to abort here and nothing to write beside the move.
    if (!ref.mounted) return;
    _listen(turn, repo.sendPrompt(chatId, prompt,
        history: history,
        replaces: replacing != null,
        omadaMember: _memberAnswering(chat, prompt)));
  }

  /// The member a turn is answered by: the one the project's Omada addresses
  /// through [prompt] — a user prompt names them in its documents, a member's
  /// reply names the next one in its text. Decided against what the library
  /// holds now; null is the main agent. The answer is not authorship: what
  /// names the author is [Message.author], stamped where the turn opens, and
  /// a member's reply is still role `assistant`. See "The room and its
  /// participants" in `lib/ui/chat/CLAUDE.md`.
  String? _memberAnswering(Chat chat, Message prompt) {
    if (!ref.read(omadaOnProvider(chat.state.project))) return null;
    final named = prompt.role == MessageRole.assistant
        ? _mentionIn(chat, prompt)
        : _memberIfKnown(chat, nameOf(authorFor(chat, prompt)));
    return named;
  }

  /// The member [name] answers for, where the library still knows them — an
  /// unknown name is prose, not an address. Null is the main agent.
  String? _memberIfKnown(Chat chat, String? name) {
    if (name == null) return null;
    return ref
            .read(promptLibraryProvider(chat.state.project))
            .find(CompletionKind.agent, name) ==
        null
        ? null
        : name;
  }

  /// Who a turn opened on [prompt] names as its author, where the project
  /// runs Omada: the one member the prompt addresses. A command is not
  /// addressed to anyone, whatever its text names — `!grep @researcher` runs
  /// a command, it does not ask researcher to speak. Omada off never stamps:
  /// the reply is the main agent's, and a label on it would claim a member
  /// authored what is the house's voice. See "The contract between direct
  /// and Omada chats" in `lib/ui/chat/CLAUDE.md`.
  String? authorFor(Chat chat, Message prompt) =>
      !ref.read(omadaOnProvider(chat.state.project)) ||
              shellBypassCommand(prompt.plainText) != null
          ? null
          : authorFrom(prompt.documents);

  /// The turn's reply. Always role `assistant` — the role is the render
  /// class, not the author; [Message.author] is what names them.
  Message _newReply({String? author}) => Message(
        id: _uuid.v4(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        parts: const [],
        author: author,
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
    // The user re-engaging is a new patience: their budget starts over, the
    // way a fresh send's would.
    _liveTurn?.round = 0;
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
    // Kept open across the round: a caller awaiting [turnDone] gets one
    // completion, at the true end, not one per attempt.
    final turn = _turns[reply.id] ?? _openTurnEntry(reply.id);
    turn.interrupted = false;
    turn.recorder.open(reply.id, existing: reply.parts);

    _listen(turn, ref.read(chatRepositoryProvider).resumeTurn(chatId,
        history: chat.messages, omadaMember: _memberResuming(chat)));
  }

  /// The member a resumed turn runs under: whoever it started as, off the
  /// reply's own [Message.author] stamp rather than the library. A member
  /// deleted or renamed since falls back to the main agent — the backend's
  /// own overlay resolution answers the same way. Null is the main agent.
  String? _memberResuming(Chat chat) {
    final last = chat.messages.lastOrNull;
    if (last == null || last.role != MessageRole.assistant) return null;
    return _memberIfKnown(chat, nameOf(last.author));
  }

  void _listen(_RunningTurn turn, Stream<AgentEvent> stream) {
    turn.sub = stream.listen(
        (event) => _onEvent(turn, event),
        onDone: () => _finishTurn(turn),
        onError: (Object e) => _onError(turn, e));
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
    await openTurn(
      chat: chat,
      prompt: prompt,
      history: chat.messages.take(chat.messages.indexOf(prompt)).toList(),
      opening: [_newReply(author: authorFor(chat, prompt))],
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

  void _onEvent(_RunningTurn turn, AgentEvent event) {
    if (_reply == null) return;

    turn.recorder.handle(event);
    switch (event) {
      // What the recorder already turned into parts. Listed rather than
      // defaulted, so a new kind of event has to be decided about here too.
      case ResponseStart():
      case TextDelta():
      case ReasoningDelta():
      case ReasoningEnd():
      case ToolCallEvent():
      case ArtifactEvent():
      case SkillInstallEvent():
        break;
      case ToolResultEvent():
      case ShellRunEvent():
        // The pair completing is the live block's end: the result and the
        // run part are what the conversation keeps of the output from here.
        state = state.copyWith(clearShellOutput: true);
        break;
      case ErrorEvent(:final message, :final retryable):
        // Whether the round can carry the turn on from this, and the first
        // line for the retry row and the failure notification. Both are
        // turn-scoped view state: the error part is what the conversation
        // keeps, and neither field outlives the turn.
        turn.retryable = retryable;
        final lineAt = message.indexOf("\n");
        turn.errorLine = lineAt < 0 ? message : message.substring(0, lineAt);
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
      case ShellOutputEvent(:final text):
        // The live view of a command's output, for the block under the label.
        // Cleared where the pair completes, in the cases above.
        state = state.copyWith(shellOutput: text);
      case StatusEvent(:final label):
        state = label == null
            ? state.copyWith(clearStatus: true)
            : state.copyWith(status: label);
      case DoneEvent(:final aborted):
        if (aborted) turn.recorder.outcome ??= TurnEnd.aborted;
        state = state.copyWith(clearShellOutput: true);
        _finishTurn(turn);
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
  Future<void> _finishTurn(_RunningTurn turn) async {
    turn.sub?.cancel();
    turn.sub = null;
    // Null is a turn that was interrupted rather than ended — the log has no
    // closing record, and `?? true` below is the same thing its reader makes
    // of one. See "Carrying on an interrupted turn".
    final TurnEnd? reason;
    if (turn.interrupted) {
      await turn.recorder.interrupt();
      reason = null;
    } else {
      reason = await turn.recorder.close();
    }
    // A retryable failure is a blip the turn is carried on from, not an
    // outcome to report: the round waits out its backoff and re-enters the
    // same resume the user's Continue button takes. The wait holds nothing —
    // the user pressing stop has to reach it first, which is what the
    // generation is for. The turn's completer stays open across rounds, so a
    // caller awaiting [turnDone] — the reminder runner, voice — gets one
    // completion, at the true end. The entry stays in the table across the
    // rounds — a retry re-opens this entry's recorder, not a fresh one whose
    // completer nobody holds — and leaves the table only at the true end.
    if (reason == TurnEnd.error &&
        turn.retryable &&
        turn.round < _roundsTotal) {
      final gen = turn.retryGen;
      final round = turn.round;
      turn.round++;
      final wait = Duration(seconds: (1 << round).clamp(1, 30));
      if (!ref.mounted) return;
      state = state.copyWith(
        retry: "Retrying (${turn.round}/$_roundsTotal) — ${turn.errorLine}",
        approvals: const [],
        questions: const [],
        runningSubAgents: const [],
      );
      await Future<void>.delayed(wait);
      if (turn.retryGen != gen || !ref.mounted) return;
      // A deleted chat has nothing to carry on.
      if (state.chat == null) return;
      await _startResume();
      return;
    }
    if (!ref.mounted) return;
    final done = turn.done;
    _turns.remove(turn.replyId);
    // Nothing is left to answer once the turn is over: the backend has already
    // answered its own outstanding questions with nothing, so a banner or a
    // panel still on screen would send its reply into the void.
    state = state.copyWith(
      // What a reload would now make of the log, so a turn that gave up is
      // offered straight away rather than only once the chat is opened again.
      chat: state.chat?.copyWith(unfinished: reason?.resumable ?? true),
      isRunning: _turns.isNotEmpty,
      approvals: const [],
      questions: const [],
      runningSubAgents: const [],
      clearRetry: true,
      clearStatus: true,
      unfinishedNotice: reason == TurnEnd.stepLimit
          ? "Step limit reached"
          : null,
    );
    done.complete(reason);
    await _notifyFailure(reason, turn.errorLine);

    // The room has settled: what was said while it spoke is said next, in
    // the order it was said. A say that opens its own turn clears the queue
    // ahead of it — everything said earlier is already on the log and this
    // is the turn the user is looking at.
    while (_said.isNotEmpty) {
      final said = _said.removeAt(0);
      await _prompt(said.text, files: said.files);
    }
    await _maybeHandoff(reason);
  }

  /// What a finished turn may hand the baton to. A reply that addresses
  /// exactly one member — and whose turn ended `done`, nothing a failure
  /// leaves carrying — schedules that member's turn, the room's sequential
  /// round, until the generation cap says the agents have had the floor long
  /// enough. The mention is read off the reply's text against the library —
  /// the member named *now* is the one handed to, the room's own wording —
  /// and scheduled through the same `_turn` path every turn takes.
  Future<void> _maybeHandoff(TurnEnd? reason) async {
    if (reason != TurnEnd.done) return;
    if (!ref.mounted) return;
    final chat = state.chat;
    if (chat == null) return;
    // Omada off is the room as it always was: nothing hands anything to
    // anyone, whatever a reply's text happens to name.
    if (!ref.read(omadaOnProvider(chat.state.project))) return;
    // A handoff wave waits for the room to settle: siblings of the turn that
    // just finished may still be speaking, and a wave started now would fork
    // the round and reorder authorship.
    if (_turns.isNotEmpty) return;
    final reply = chat.messages.lastOrNull;
    if (reply == null || reply.role != MessageRole.assistant) return;
    // A decline is on the record: the member was addressed and passed, and
    // nothing follows it.
    if (_isPass(reply)) return;
    final named = _mentionIn(chat, reply);
    if (named == null) return;
    _generation++;
    // The addressed member's reply is generation one; the cap counts the
    // waves a round may run, and reaching it blocks the next.
    if (_generation >= _maxGenerations) return;
    await openTurn(
      chat: chat,
      prompt: reply,
      history: chat.messages,
      // The next reply is authored by the member handed to. The stamp
      // carries the sigil, the way every author stamp does.
      opening: [_newReply(author: "${CompletionKind.agent.trigger}$named")],
    );
  }

  /// The one member [reply] names by handle, as the composer's own
  /// `_mention` reads one. Null where it names none, or more than one — a
  /// multi-mention is a round, and rounds are not sequential handoffs.
  String? _mentionIn(Chat chat, Message reply) =>
      singleAgentMention(reply.plainText,
          ref.read(promptLibraryProvider(chat.state.project)));

  /// Whether a reply says nothing but that its author passes: word for word,
  /// so a longer reply is a reply and the convention is unambiguous.
  bool _isPass(Message reply) => reply.plainText.trim() == passWord;

  /// How deep the agent-to-agent rounds of a round may go: dispatch waves,
  /// not turns — a three-member fan-out is one generation whatever it fans
  /// out to. The project's override wins over the app default, and the user
  /// speaking resets the count: the cap is about agents talking to each
  /// other without end, not about how long a conversation may run.
  int get _maxGenerations {
    final project = state.chat?.state.project;
    return ref.read(projectSettingsProvider(project)).omadaMaxGenerations ??
        ref.read(appSettingsProvider).omadaMaxGenerations;
  }

  /// Generations dispatched since the user last spoke. Zero is "the user
  /// started this round"; the first handoff wave makes it one.
  int _generation = 0;

  /// What this turn is allowed: the setting, resolved at the round the same
  /// way the approve mode is, so an edit reaches the next failure rather than
  /// the next launch.
  int get _roundsTotal => ref.read(appSettingsProvider).turnRetries;

  /// The notification. A failure the user cannot see is a failure the app has
  /// to say — the turn is over, the chat is on disk, and the tap opens it.
  /// [line] is what the failing turn reported. Gated on the app being hidden
  /// and the chat not headless: a reminder's completion is the scheduler's,
  /// and a second would be a double. Where the platform has no notification
  /// route the port is the no-op it always was.
  Future<void> _notifyFailure(TurnEnd? reason, String line) async {
    if (reason != TurnEnd.error) return;
    if (!ref.read(appHiddenProvider)) return;
    if (await _isHeadless()) return;
    final alarms = ref.read(reminderAlarmsProvider);
    final title = state.chat?.state.title ?? "Chat failed";
    await alarms.notify(
      title: title,
      body: line.isEmpty ? "The turn failed." : line,
      chatId: chatId,
      channel: ReminderAlarms.turnFailureChannel,
    );
  }

  /// A chat nobody watches — a reminder's — is the scheduler's to notify.
  Future<bool> _isHeadless() async =>
      (await ref.read(chatRepositoryProvider).loadMeta(chatId)).headless == true;

  void _onError(_RunningTurn turn, Object e) {
    turn.retryable = false;
    final message = e.toString();
    final lineAt = message.indexOf("\n");
    turn.errorLine = lineAt < 0 ? message : message.substring(0, lineAt);
    turn.recorder.handle(ErrorEvent(message));
    _finishTurn(turn);
  }

  /// Set before the abort is awaited, though `DoneEvent.aborted` would say the
  /// same: killing the turn closes the stream, and a backend that closed it
  /// without the event would let `onDone` reach [_finishTurn] first and record
  /// the turn as having finished.
  @override
  Future<void> abort() async {
    final turn = _liveTurn;
    if (turn == null) return;
    turn.retryGen++;
    turn.recorder.outcome = TurnEnd.aborted;
    await ref.read(chatRepositoryProvider).abort(chatId);
    await _finishTurn(turn);
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
    final turn = _liveTurn;
    if (turn == null || !state.isRunning) return;
    turn.retryGen++;
    turn.interrupted = true;
    await ref.read(chatRepositoryProvider).abort(chatId);
    await _finishTurn(turn);
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

/// One live turn of the room: everything that was a controller field when a
/// turn was the only thing a chat could run. The recorder is built per entry
/// — its one-reply assumption is per-instance, which is what keeps
/// [TurnRecorder] unchanged under parallel turns — and the fields below it
/// are the retry machinery, scoped to the turn they carry.
class _RunningTurn {
  /// [onParts] is wired late, from [attach]: the recorder wants the turn it
  /// belongs to, and the turn does not exist until its constructor returns.
  factory _RunningTurn(
      {required String replyId,
      required Completer<TurnEnd?> done,
      required Future<void> Function(List<ChatRecord>) append}) {
    final turn = _RunningTurn._(replyId: replyId, done: done);
    turn.recorder = TurnRecorder(append: append, onParts: (parts) {
      if (turn.onParts != null) turn.onParts!(turn, parts);
    });
    return turn;
  }

  _RunningTurn._({required this.replyId, required this.done});

  /// The reply this turn writes, and the table's key.
  final String replyId;

  /// Everything the turn's events become: the reply's parts, and the records
  /// that persist them.
  late final TurnRecorder recorder;

  /// The controller's own fold of the parts into the conversation — wired at
  /// open, so a recorder built for one chat's log cannot outlive it.
  void Function(_RunningTurn turn, List<MessagePart> parts)? onParts;

  /// Completes at the turn's true end — across retry rounds, one completion.
  final Completer<TurnEnd?> done;

  /// The turn's stream subscription, cancelled in [_finishTurn].
  StreamSubscription<AgentEvent>? sub;

  /// This turn is being stopped rather than ended — see [ChatController.interrupt].
  bool interrupted = false;

  /// Bumped by abort and interrupt so a pending retry cannot fire after the
  /// user pressed stop — this turn's generation, not the room's.
  int retryGen = 0;

  /// Whether the turn's last failure can be carried on from, and the line for
  /// the retry row and the failure notification.
  bool retryable = false;
  String errorLine = "";

  /// Retry rounds spent on this turn so far.
  int round = 0;
}

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