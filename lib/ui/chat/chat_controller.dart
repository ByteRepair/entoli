import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../domain/agent_backend.dart";
import "../../domain/models.dart";
import "../../providers.dart";

/// Per-chat state container exposed to the UI.
class ChatViewState {
  ChatViewState({
    this.chat,
    this.isRunning = false,
    this.approvals = const [],
    this.retry,
  });
  final Chat? chat;
  final bool isRunning;
  final List<ToolApproval> approvals;

  /// Set while the backend is retrying a failed attempt. Transient: it belongs
  /// to the running turn, not to the conversation, so it is never persisted.
  final String? retry;

  ChatViewState copyWith({
    Chat? chat,
    bool? isRunning,
    List<ToolApproval>? approvals,
    String? retry,
    bool clearRetry = false,
  }) =>
      ChatViewState(
        chat: chat ?? this.chat,
        isRunning: isRunning ?? this.isRunning,
        approvals: approvals ?? this.approvals,
        retry: clearRetry ? null : (retry ?? this.retry),
      );
}

/// Drives a single chat: loads from store, sends prompts, accumulates streamed
/// events into messages, persists conv.json after each turn.
class ChatController extends Notifier<ChatViewState> {
  ChatController(this.chatId);

  final String chatId;
  final _uuid = const Uuid();
  StreamSubscription<AgentEvent>? _sub;
  Timer? _stall;

  /// Deltas arrive per token; the UI only needs them per frame.
  final StringBuffer _pending = StringBuffer();
  Timer? _flush;
  bool _pendingIsReasoning = false;

  @override
  ChatViewState build() {
    ref.onDispose(() {
      _sub?.cancel();
      _stall?.cancel();
      _flush?.cancel();
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

  void _bufferDelta(String text, {bool reasoning = false}) {
    if (reasoning != _pendingIsReasoning) _flushDeltas();
    _pendingIsReasoning = reasoning;
    _pending.write(text);
    _flush ??= Timer(const Duration(milliseconds: 16), _flushDeltas);
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
        parts.add(MessagePart.reasoning(text: text));
      } else {
        parts[at] = ReasoningPart(text: "${(parts[at] as ReasoningPart).text}$text");
      }
    } else if (last is TextPart) {
      parts[parts.length - 1] = TextPart(text: "${last.text}$text");
    } else {
      parts.add(MessagePart.text(text: text));
    }
    _writeReply(parts);
  }

  /// A block is timed once it closes, so an untimed one is still being
  /// written. Searched for rather than assumed last: another part can land
  /// between a block's deltas and the event that closes it.
  int _openReasoningAt(List<MessagePart> parts) =>
      parts.lastIndexWhere((p) => p is ReasoningPart && p.durationMs == null);

  /// Close the thinking block being written. The backend's text wins over what
  /// streamed: a provider that sends no deltas still reports the whole of it.
  void _endReasoning(String? text, Duration? duration) {
    _flushDeltas();
    final parts = List<MessagePart>.from(_reply?.parts ?? const []);
    final at = _openReasoningAt(parts);
    final open = at < 0 ? null : parts[at] as ReasoningPart;
    final body = text != null && text.isNotEmpty ? text : (open?.text ?? "");
    if (body.isEmpty && open == null) return;

    final sealed = MessagePart.reasoning(text: body, durationMs: duration?.inMilliseconds);
    if (open == null) {
      parts.add(sealed);
    } else {
      parts[at] = sealed;
    }
    _writeReply(parts);
  }

  /// (Re)start the clock on a turn that is producing nothing.
  void _watchForStall() {
    final timeout = ref.read(turnStallTimeoutProvider);
    _stall?.cancel();
    _stall = Timer(timeout, () => _giveUp(timeout));
  }

  /// End a stalled turn on our terms: keep whatever the backend last told us
  /// about the trouble, stop the backend, and leave the user a retry.
  Future<void> _giveUp(Duration waited) async {
    if (!state.isRunning) return;
    final blame = state.retry;
    _appendError(
      blame == null
          ? "No response after ${waited.inSeconds}s. Stopped waiting."
          : "Gave up after ${waited.inSeconds}s. $blame",
    );
    await abort();
  }

  void _appendError(String message) {
    final reply = _reply;
    if (reply == null) return;
    _flushDeltas();
    _writeReply([...?_reply?.parts, MessagePart.error(message: message)]);
  }

  /// Retitle in place. Reloading instead would dispose a running turn.
  void applyTitle(String title) {
    final chat = state.chat;
    if (chat == null) return;
    state = state.copyWith(chat: chat.copyWith(state: chat.state.copyWith(title: title)));
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
    state = state.copyWith(chat: updatedChat, isRunning: true, clearRetry: true);
    await repo.save(updatedChat);

    final stream = repo.sendPrompt(chatId, text, attachments: attachments);
    _watchForStall();
    _sub?.cancel();
    _sub = stream.listen(
      (event) => _onEvent(event),
      onDone: _finishTurn,
      onError: (e) => _onError(e),
    );
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

    // Output means the turn is alive; a retry notice means the opposite, so it
    // deliberately does not reset the clock.
    switch (event) {
      case TextDelta(:final text):
        _watchForStall();
        _bufferDelta(text);
      case ReasoningDelta(:final text):
        _watchForStall();
        _bufferDelta(text, reasoning: true);
      case ReasoningEnd(:final text, :final duration):
        _watchForStall();
        _endReasoning(text, duration);
      case ToolCallEvent(:final call):
        _watchForStall();
        _appendPart(MessagePart.toolCall(toolCall: call));
      case ToolResultEvent(:final result):
        _watchForStall();
        _appendPart(MessagePart.toolResult(result: result));
      case ErrorEvent(:final message):
        _appendError(message);
      case ApprovalRequestEvent(:final approval):
        state = state.copyWith(approvals: [...state.approvals, approval]);
      case RetryEvent(:final attempt, :final message):
        state = state.copyWith(retry: "Attempt $attempt failed: $message");
      case DoneEvent():
        _finishTurn();
    }
  }

  void _appendPart(MessagePart part) {
    _flushDeltas();
    _writeReply([...?_reply?.parts, part]);
  }

  void _finishTurn() {
    _flushDeltas();
    _stall?.cancel();
    _stall = null;
    _sub?.cancel();
    _sub = null;
    final chat = state.chat;
    if (chat != null) {
      ref.read(chatRepositoryProvider).save(chat);
    }
    state = state.copyWith(isRunning: false, clearRetry: true);
  }

  void _onError(Object e) {
    _appendError(e.toString());
    _finishTurn();
  }

  Future<void> abort() async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.abort(chatId);
    _finishTurn();
  }

  Future<void> respondApproval(String approvalId, ApprovalResponse r) async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.respondApproval(chatId, approvalId, r);
    state = state.copyWith(
      approvals: state.approvals.where((a) => a.id != approvalId).toList(),
    );
  }
}

final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatViewState, String>(ChatController.new);