import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

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
  }) =>
      ChatViewState(
        chat: chat ?? this.chat,
        isRunning: isRunning ?? this.isRunning,
        approvals: approvals ?? this.approvals,
        questions: questions ?? this.questions,
        runningSubAgents: runningSubAgents ?? this.runningSubAgents,
        retry: clearRetry ? null : (retry ?? this.retry),
        status: clearStatus ? null : (status ?? this.status),
      );
}

/// Drives a single chat: loads from store, sends prompts, accumulates streamed
/// events into messages, and appends them to the chat's log as they arrive.
class ChatController extends Notifier<ChatViewState> {
  ChatController(this.chatId);

  final String chatId;
  final _uuid = const Uuid();
  StreamSubscription<AgentEvent>? _sub;

  /// Everything that turns this turn's events into the reply's parts and the
  /// records that persist them. Shared with `SubAgentRunner`, which keeps one
  /// per `task` call — see [TurnRecorder].
  late final TurnRecorder _recorder;

  @override
  ChatViewState build() {
    _recorder = TurnRecorder(
      append: (records) => ref.read(chatRepositoryProvider).append(chatId, records),
      onParts: _writeReply,
    );
    ref.onDispose(() {
      _sub?.cancel();
      _recorder.dispose();
    });
    _load();
    return ChatViewState();
  }

  /// The reply being written. It is always the last message of a running turn.
  Message? get _reply {
    final messages = state.chat?.messages;
    return messages == null || messages.isEmpty ? null : messages.last;
  }

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

  /// Name the chat after what started it. Nothing waits on this: it is a model
  /// call of its own, and the turn it belongs to is already under way.
  Future<void> _nameChat(String prompt) async {
    final title = await ref.read(chatRepositoryProvider).suggestTitle(prompt);
    final chat = state.chat;
    if (title == null || chat == null || !ref.mounted) return;
    applyTitle(title);
    await ref.read(chatRepositoryProvider).retitle(chatId, title);
    if (!ref.mounted) return;
    ref.invalidate(chatListProvider);
  }

  Future<void> _load() async {
    final repo = ref.read(chatRepositoryProvider);
    final chat = await repo.openChat(chatId);
    if (!ref.mounted) return;
    state = state.copyWith(chat: chat);
  }

  /// The composer's own path: what it is holding becomes files under the chat
  /// before anything else, since from here on a prompt is its parts.
  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
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

    final userMsg = repo.composeUserPrompt(text, files: files);
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
    _recorder.open(opening.last.id);
    await _recorder.write(recordsOf(opening,
        siblingOf: replacing?.id,
        replacing: replacing != null && !chat.worthAThread(replacing)));
    // Only the first: a later message changes nothing the sidebar shows, and
    // refreshing it re-reads every chat off disk.
    if (isFirst) {
      ref.invalidate(chatListProvider);
      unawaited(_nameChat(prompt.plainText));
    }

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
  Future<void> resume() async {
    final chat = state.chat;
    if (chat == null || state.isRunning || !chat.unfinished) return;
    final reply = chat.messages.last;

    state = state.copyWith(isRunning: true, clearRetry: true, clearStatus: true);
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
      case ErrorEvent():
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
    final reason = await _recorder.close();
    if (!ref.mounted) return;
    // Nothing is left to answer once the turn is over: the backend has already
    // answered its own outstanding questions with nothing, so a banner or a
    // panel still on screen would send its reply into the void.
    state = state.copyWith(
      // What a reload would now make of the log, so a turn that gave up is
      // offered straight away rather than only once the chat is opened again.
      chat: state.chat?.copyWith(unfinished: reason.resumable),
      isRunning: false,
      approvals: const [],
      questions: const [],
      runningSubAgents: const [],
      clearRetry: true,
      clearStatus: true,
    );
  }

  void _onError(Object e) {
    _recorder.handle(ErrorEvent(e.toString()));
    _finishTurn();
  }

  /// Set before the abort is awaited, though `DoneEvent.aborted` would say the
  /// same: killing the turn closes the stream, and a backend that closed it
  /// without the event would let `onDone` reach [_finishTurn] first and record
  /// the turn as having finished.
  Future<void> abort() async {
    _recorder.outcome = TurnEnd.aborted;
    await ref.read(chatRepositoryProvider).abort(chatId);
    await _finishTurn();
  }

  Future<void> respondApproval(String approvalId, ApprovalResponse r) async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.respondApproval(chatId, approvalId, r);
    state = state.copyWith(
        approvals: state.approvals.where((a) => a.id != approvalId).toList());
  }

  /// Answer a request the panel was showing. One entry per question it held,
  /// null where nothing was picked.
  Future<void> answerQuestions(String requestId, List<String?> answers) async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.respondQuestions(chatId, requestId, answers);
    state = state.copyWith(
        questions: state.questions.where((r) => r.id != requestId).toList());
  }
}

final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatViewState, String>(ChatController.new);