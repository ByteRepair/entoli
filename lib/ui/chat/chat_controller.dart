import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../domain/agent_backend.dart";
import "../../domain/ask.dart";
import "../../domain/chat_log.dart";
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

  /// Deltas arrive per token; the UI only needs them per frame.
  final StringBuffer _pending = StringBuffer();
  Timer? _flush;
  bool _pendingIsReasoning = false;

  /// The reply being logged, and its parts as the log last saw them. A
  /// checkpoint writes the difference, so a part that has not changed is not
  /// written twice.
  String? _loggedId;
  List<MessagePart> _logged = const [];

  /// Text grows without any event to hang a write off, so a delta arms this
  /// and the log catches up a second later. Everything else is written the
  /// moment it lands. One-shot rather than periodic, like [_flush]: a timer
  /// that keeps rearming itself is a widget test that never settles.
  Timer? _checkpoint;
  static const _checkpointEvery = Duration(seconds: 1);

  /// Appends run one at a time and in order: the log is a file being added to,
  /// and two writers would interleave lines. Queued work reads the state when
  /// it runs, so calls that pile up behind a slow write collapse into one.
  ///
  /// Null until the first one rather than seeded with a completed future. A
  /// `Future.value()` built when the controller is — which in a widget test is
  /// on the fake clock — only completes when the tree is pumped, and the first
  /// append is awaited from inside `runAsync`, where it cannot be.
  Future<void>? _queue;

  /// The response being streamed. Every part produced while it is set is
  /// stamped with it, which is what lets a turn be handed back to a provider
  /// one response at a time — see [MessagePart].
  String? _responseId;

  /// How the turn ended, where something other than the model decided it. Null
  /// means it simply finished. Turn-scoped rather than read off the reply's
  /// parts: a resumed turn adds to a message that may already hold the
  /// [ErrorPart] the last attempt ended on. An abort wins over an error —
  /// killing a turn is a good way to make it fail.
  TurnEnd? _outcome;

  @override
  ChatViewState build() {
    ref.onDispose(() {
      _sub?.cancel();
      _flush?.cancel();
      _checkpoint?.cancel();
    });
    _load();
    return ChatViewState();
  }

  /// Write whatever the reply has grown by, and [then] after it. Parts are
  /// compared rather than counted: a thinking block is closed in place, and a
  /// provider that interleaves parts can close one that is no longer last.
  ///
  /// Text that only grew is written as the piece it grew by. Writing the part
  /// whole each time would cost its length once per checkpoint, so a reply
  /// streaming for two minutes would be written a hundred times over.
  /// [forMessage] is passed rather than read here: queued work runs later, and
  /// by then the turn it belongs to may have cleared itself.
  Future<void> _appendChanged(String forMessage,
      {List<ChatRecord> then = const []}) async {
    final reply = _reply;
    final parts = reply?.id == forMessage ? reply!.parts : const <MessagePart>[];
    final records = <ChatRecord>[];
    for (var i = 0; i < parts.length; i++) {
      if (i >= _logged.length) {
        records.add(ChatRecord.part(messageId: forMessage, index: i, part: parts[i]));
        continue;
      }
      if (_logged[i] == parts[i]) continue;
      final grown = textGrownFrom(_logged[i], parts[i]);
      records.add(grown == null
          ? ChatRecord.part(messageId: forMessage, index: i, part: parts[i])
          : ChatRecord.append(messageId: forMessage, index: i, text: grown));
    }
    records.addAll(then);
    if (records.isEmpty) return;
    await ref.read(chatRepositoryProvider).append(chatId, records);
    // After the write, so a failed one is retried by the next checkpoint
    // rather than treated as landed.
    if (parts.isNotEmpty) _logged = List.of(parts);
  }

  /// Put [work] at the end of the append queue. Failures are swallowed on
  /// purpose: a checkpoint that could not be written is not worth ending a
  /// turn over, and the next one writes what this one missed.
  Future<void> _enqueue(Future<void> Function() work) {
    final queued = _queue;
    return _queue =
        (queued == null ? Future<void>.sync(work) : queued.then((_) => work()))
            .catchError((Object _) {});
  }

  void _checkpointLog() {
    final logging = _loggedId;
    if (logging != null) unawaited(_enqueue(() => _appendChanged(logging)));
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

  void _bufferDelta(String text, {bool reasoning = false}) {
    if (reasoning != _pendingIsReasoning) _flushDeltas();
    _pendingIsReasoning = reasoning;
    _pending.write(text);
    _flush ??= Timer(const Duration(milliseconds: 16), _flushDeltas);
    _checkpoint ??= Timer(_checkpointEvery, () {
      _checkpoint = null;
      _flushDeltas();
      _checkpointLog();
    });
  }

  /// Fold everything buffered into the reply's trailing part of the same kind.
  /// Must run before anything else is appended, so parts keep their arrival
  /// order.
  void _flushDeltas() {
    _flush?.cancel();
    _flush = null;
    if (_pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();

    final reply = _reply;
    if (reply == null) return;
    final parts = List<MessagePart>.from(reply.parts);
    final last = parts.lastOrNull;
    if (_pendingIsReasoning) {
      final at = _openReasoningAt(parts);
      if (at < 0) {
        parts.add(MessagePart.reasoning(text: text, responseId: _responseId));
      } else {
        final open = parts[at] as ReasoningPart;
        parts[at] = open.copyWith(text: "${open.text}$text");
      }
    } else if (last is TextPart && last.responseId == _responseId) {
      parts[parts.length - 1] = last.copyWith(text: "${last.text}$text");
    } else {
      parts.add(MessagePart.text(text: text, responseId: _responseId));
    }
    _writeReply(parts);
  }

  /// A block is timed once it closes, so an untimed one is still being
  /// written. Searched for rather than assumed last: another part can land
  /// between a block's deltas and the event that closes it. Only this
  /// response's: a block left open by the one before is not this one's to fill.
  int _openReasoningAt(List<MessagePart> parts) => parts.lastIndexWhere(
      (p) => p is ReasoningPart && p.durationMs == null && p.responseId == _responseId);

  /// Close the thinking block being written. The backend's text wins over what
  /// streamed: a provider that sends no deltas still reports the whole of it.
  void _endReasoning(String? text, Duration? duration, String? signature) {
    _flushDeltas();
    final parts = List<MessagePart>.from(_reply?.parts ?? const []);
    final at = _openReasoningAt(parts);
    final open = at < 0 ? null : parts[at] as ReasoningPart;
    final body = text != null && text.isNotEmpty ? text : (open?.text ?? "");
    if (body.isEmpty && open == null) return;

    final sealed = MessagePart.reasoning(
      text: body,
      durationMs: duration?.inMilliseconds,
      signature: signature,
      responseId: _responseId,
    );
    if (open == null) {
      parts.add(sealed);
    } else {
      parts[at] = sealed;
    }
    _writeReply(parts);
    _checkpointLog();
  }

  void _appendError(String message) {
    final reply = _reply;
    if (reply == null) return;
    _outcome ??= TurnEnd.error;
    _flushDeltas();
    _writeReply([...?_reply?.parts, MessagePart.error(message: message)]);
    _checkpointLog();
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
    _openTurn(assistantMsg.id);
    await _enqueue(() => repo.append(chatId, recordsOf([userMsg, assistantMsg])));
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
    _openTurn(reply.id, logged: reply.parts);

    _listen(ref.read(chatRepositoryProvider)
        .resumeTurn(chatId, history: chat.messages));
  }

  /// The bookkeeping every turn opens with. [logged] is what the log already
  /// holds of the reply — nothing for a new turn, its parts so far for one
  /// being carried on, so a checkpoint writes only what this turn adds.
  void _openTurn(String replyId, {List<MessagePart> logged = const []}) {
    _outcome = null;
    _responseId = null;
    _loggedId = replyId;
    _logged = logged;
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

    switch (event) {
      case ResponseStart(:final id):
        // Before the id moves: what is buffered was said by the response that
        // is ending, not the one starting.
        _flushDeltas();
        _responseId = id;
      case TextDelta(:final text):
        _bufferDelta(text);
      case ReasoningDelta(:final text):
        _bufferDelta(text, reasoning: true);
      case ReasoningEnd(:final text, :final duration, :final signature):
        _endReasoning(text, duration, signature);
      case ToolCallEvent(:final call):
        _appendPart(MessagePart.toolCall(toolCall: call));
      case ToolResultEvent(:final result):
        _appendPart(MessagePart.toolResult(result: result));
      case ErrorEvent(:final message):
        _appendError(message);
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
      case InfoEvent():
        break;
      case DoneEvent(:final aborted):
        if (aborted) _outcome ??= TurnEnd.aborted;
        _finishTurn();
    }
  }

  /// Every discrete part goes through here, and so do its record and the
  /// response it belongs to: a new kind of event cannot forget either.
  void _appendPart(MessagePart part) {
    _flushDeltas();
    _writeReply([...?_reply?.parts, _inResponse(part)]);
    _checkpointLog();
  }

  /// Stamp a part with the response being streamed, where it has somewhere to
  /// put it. A result belongs to the call it answers and an error to nobody, so
  /// neither carries one.
  MessagePart _inResponse(MessagePart part) => switch (part) {
        TextPart() => part.copyWith(responseId: _responseId),
        ReasoningPart() => part.copyWith(responseId: _responseId),
        ToolCallPart() => part.copyWith(responseId: _responseId),
        _ => part,
      };

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
    _flushDeltas();
    _checkpoint?.cancel();
    _checkpoint = null;
    _sub?.cancel();
    _sub = null;
    final ending = _loggedId;
    final reason = _outcome ?? TurnEnd.done;
    if (ending != null) {
      _loggedId = null;
      // The last of the reply and the record closing it in one write, since
      // every append is an open and a close of the file.
      await _enqueue(() => _appendChanged(ending,
          then: [ChatRecord.turnEnd(messageId: ending, reason: reason)]));
    }
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
    _appendError(e.toString());
    _finishTurn();
  }

  /// Set before the abort is awaited, though `DoneEvent.aborted` would say the
  /// same: killing the turn closes the stream, and a backend that closed it
  /// without the event would let `onDone` reach [_finishTurn] first and record
  /// the turn as having finished.
  Future<void> abort() async {
    _outcome = TurnEnd.aborted;
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