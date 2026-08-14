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
  final Map<String, Message> _assistantBuf = {};

  @override
  ChatViewState build() {
    ref.onDispose(() {
      _sub?.cancel();
      _stall?.cancel();
    });
    _load();
    return ChatViewState();
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
    final chat = state.chat;
    final assistant = _assistantBuf[chatId];
    if (chat == null || assistant == null || chat.messages.isEmpty) return;
    final updated = assistant.copyWith(
      parts: [...assistant.parts, MessagePart.error(message: message)],
    );
    _assistantBuf[chatId] = updated;
    final msgs = List<Message>.from(chat.messages);
    msgs[msgs.length - 1] = updated;
    state = state.copyWith(chat: chat.copyWith(messages: msgs));
  }

  Future<void> _load() async {
    final repo = ref.read(chatRepositoryProvider);
    final chat = await repo.openChat(chatId);
    if (!ref.mounted) return;
    state = state.copyWith(chat: chat);
  }

  Future<void> send(String text) async {
    final repo = ref.read(chatRepositoryProvider);
    final chat = state.chat;
    if (chat == null || state.isRunning) return;

    final userMsg = Message(
      id: _uuid.v4(),
      role: MessageRole.user,
      createdAt: DateTime.now(),
      parts: [MessagePart.text(text: text)],
    );
    final assistantMsg = Message(
      id: _uuid.v4(),
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
      parts: [],
    );
    _assistantBuf[chatId] = assistantMsg;

    final updatedChat = Chat(
      state: chat.state.copyWith(updatedAt: DateTime.now()),
      messages: [...chat.messages, userMsg, assistantMsg],
    );
    state = state.copyWith(chat: updatedChat, isRunning: true, clearRetry: true);
    await repo.save(updatedChat);

    final meta = await repo.loadMeta(chatId);
    final stream =
        repo.sendPrompt(chatId, text, model: meta.model, provider: meta.provider);
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
    final index = chat.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return null;
    for (var i = index; i >= 0; i--) {
      if (chat.messages[i].role == MessageRole.user) return chat.messages[i];
    }
    return null;
  }

  String _textOf(Message message) =>
      message.parts.whereType<TextPart>().map((p) => p.text).join("\n");

  /// What the agent is told before a resent turn. The live session saw the
  /// discarded exchange, so the retry runs on a fresh one seeded with this.
  String _transcript(List<Message> messages) {
    final buffer = StringBuffer();
    for (final m in messages) {
      final text = _textOf(m).trim();
      if (text.isEmpty) continue;
      buffer.writeln("${m.role.name}: $text");
      buffer.writeln();
    }
    final body = buffer.toString().trim();
    return body.isEmpty ? "" : "Earlier in this conversation:\n\n$body";
  }

  /// Drop the turn starting at [prompt] and run it again with [text].
  Future<void> _resend(Message prompt, String text) async {
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final index = chat.messages.indexOf(prompt);
    if (index < 0) return;

    final kept = chat.messages.sublist(0, index);
    final truncated = chat.copyWith(messages: kept);
    state = state.copyWith(chat: truncated);

    final repo = ref.read(chatRepositoryProvider);
    await repo.save(truncated);
    await repo.resetSession(chatId, transcript: _transcript(kept));
    await send(text);
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
    if (prompt != null) await _resend(prompt, _textOf(prompt));
  }

  void _onEvent(AgentEvent event) {
    final chat = state.chat;
    if (chat == null) return;
    final assistant = _assistantBuf[chatId];
    if (assistant == null) return;

    final parts = List<MessagePart>.from(assistant.parts);
    switch (event) {
      // Output means the turn is alive; a retry notice means the opposite, so
      // it deliberately does not reset the clock.
      case TextDelta() || ToolCallEvent() || ToolResultEvent():
        _watchForStall();
      default:
    }
    switch (event) {
      case TextDelta(:final text):
        if (parts.isNotEmpty && parts.last is TextPart) {
          final last = parts.last as TextPart;
          parts[parts.length - 1] = TextPart(text: "${last.text}$text");
        } else {
          parts.add(MessagePart.text(text: text));
        }
      case ToolCallEvent(:final call):
        parts.add(MessagePart.toolCall(toolCall: call));
      case ToolResultEvent(:final result):
        parts.add(MessagePart.toolResult(result: result));
      case ApprovalRequestEvent(:final approval):
        state = state.copyWith(approvals: [...state.approvals, approval]);
      case RetryEvent(:final attempt, :final message):
        state = state.copyWith(retry: "Attempt $attempt failed: $message");
        return;
      case DoneEvent():
        _finishTurn();
        return;
      case ErrorEvent(:final message):
        parts.add(MessagePart.error(message: message));
    }

    final updatedAssistant = assistant.copyWith(parts: parts);
    _assistantBuf[chatId] = updatedAssistant;
    final msgs = List<Message>.from(chat.messages);
    msgs[msgs.length - 1] = updatedAssistant;
    state = state.copyWith(chat: chat.copyWith(messages: msgs));
  }

  void _finishTurn() {
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