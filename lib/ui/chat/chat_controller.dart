import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../domain/agent_backend.dart";
import "../../domain/ask.dart";
import "../../domain/chat_log.dart";
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

  ChatViewState copyWith({
    Chat? chat,
    bool? isRunning,
    List<ToolApproval>? approvals,
    List<AskRequest>? questions,
    List<SubAgentStartEvent>? runningSubAgents,
    String? retry,
    bool clearRetry = false,
  }) =>
      ChatViewState(
        chat: chat ?? this.chat,
        isRunning: isRunning ?? this.isRunning,
        approvals: approvals ?? this.approvals,
        questions: questions ?? this.questions,
        runningSubAgents: runningSubAgents ?? this.runningSubAgents,
        retry: clearRetry ? null : (retry ?? this.retry),
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

  /// Retitle in place. Reloading instead would dispose a running turn.
  void applyTitle(String title) {
    final chat = state.chat;
    if (chat == null) return;
    state = state.copyWith(chat: chat.copyWith(state: chat.state.copyWith(title: title)));
  }

  /// Name the chat after what started it. Nothing waits on this: it is a model
  /// call of its own, and the turn it belongs to is already under way.
  Future<void> _nameChat(String prompt) async {
    final title = await ref.read(chatRepositoryProvider).suggestTitle(prompt);
    final chat = state.chat;
    if (title == null || chat == null || !ref.mounted) return;
    applyTitle(title);
    await ref.read(chatRepositoryProvider).retitle(chat.state, title);
    if (!ref.mounted) return;
    ref.invalidate(chatListProvider);
  }

  Future<void> _load() async {
    final repo = ref.read(chatRepositoryProvider);
    final chat = await repo.openChat(chatId);
    if (!ref.mounted) return;
    state = state.copyWith(chat: chat);
  }

  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
    final repo = ref.read(chatRepositoryProvider);
    final chat = state.chat;
    if (chat == null || state.isRunning) return;

    final userMsg = Message(
      id: _uuid.v4(),
      role: MessageRole.user,
      createdAt: DateTime.now(),
      // Files first, the order they are sent in and the order a resend rebuilds.
      parts: [...await repo.saveAttachments(chatId, attachments), MessagePart.text(text: text)],
    );
    final assistantMsg = Message(
      id: _uuid.v4(),
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
      parts: [],
    );

    final updatedChat = Chat(
      state: chat.state.copyWith(updatedAt: DateTime.now()),
      messages: [...chat.messages, userMsg, assistantMsg],
    );
    final isFirst = chat.messages.isEmpty;
    state = state.copyWith(chat: updatedChat, isRunning: true, clearRetry: true);
    // The prompt and the empty reply go down before the turn starts, so a chat
    // killed before the model says anything still shows what was asked.
    await repo.saveState(updatedChat.state);
    _recorder.open(assistantMsg.id);
    await _recorder.write(recordsOf([userMsg, assistantMsg]));
    // Only the first: a later message changes nothing the sidebar shows, and
    // refreshing it re-reads every chat off disk.
    if (isFirst) {
      ref.invalidate(chatListProvider);
      unawaited(_nameChat(text));
    }

    // `chat` is the conversation before this turn was added to it, which is
    // what a backend holding no session for the chat needs to be told.
    _listen(repo.sendPrompt(chatId, text,
        attachments: attachments, history: chat.messages));
  }

  /// Carry on the turn the chat was cut off in. What this produces goes on the
  /// end of the reply that is already there, closed by a second [TurnEndRecord]
  /// when it finishes.
  Future<void> resume() async {
    final chat = state.chat;
    if (chat == null || state.isRunning || !chat.unfinished) return;
    final reply = chat.messages.last;

    state = state.copyWith(isRunning: true, clearRetry: true);
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

  /// Drop the turn starting at [prompt] and run it again with [text]. What it
  /// carried goes with it: rewinding forgets the message, not its resources.
  Future<void> _resend(Message prompt, String text) async {
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final index = chat.messages.indexOf(prompt);
    if (index < 0) return;

    final repo = ref.read(chatRepositoryProvider);
    final attachments = await repo.loadAttachments(chatId, prompt);
    state = state.copyWith(chat: await repo.rewind(chat, index));
    await send(text, attachments: attachments);
  }

  /// Resend a message with new text, discarding the replies it drew.
  Future<void> editAndResend(String messageId, String text) async {
    final chat = state.chat;
    if (chat == null) return;
    final prompt = _promptFor(chat, messageId);
    if (prompt != null) await _resend(prompt, text);
  }

  /// Run the turn again unchanged. Works from either side of the exchange.
  Future<void> regenerate(String messageId) async {
    final chat = state.chat;
    if (chat == null) return;
    final prompt = _promptFor(chat, messageId);
    if (prompt != null) await _resend(prompt, prompt.plainText);
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