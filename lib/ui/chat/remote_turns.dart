import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/sync_hub.dart";
import "../../domain/models.dart";
import "../../domain/sync/protocol.dart";
import "../../providers.dart";
import "chat_controller.dart";

/// This device's end of a chat somebody else is watching or driving.
///
/// Nothing about a turn moves: a prompt typed on a mirror is run *here*, by
/// the same [ChatController] a locally typed one goes through, against the
/// same model and the same workspace. What crosses the wire is the asking and
/// the answering.
///
/// It holds one controller open per watched chat, which is what makes a turn
/// visible at the other end at all — whether one is running, what it is
/// waiting to be allowed, what it is waiting to be told. None of that is in
/// `conv.jsonl`, so nothing else would carry it.
///
/// Read once for its effect, like `TurnKeepAlive`: it registers itself on the
/// hub in its constructor and nothing ever asks it anything.
class RemoteTurnDriver implements RemoteTurns {
  RemoteTurnDriver(this._ref, this._hub) {
    _hub.remoteTurns = this;
    _hub.servedChats.addListener(_served);
    _served();
  }

  final Ref _ref;
  final SyncHub _hub;
  final _watching = <String, ProviderSubscription<ChatViewState>>{};

  /// What was last sent for each chat. `ChatViewState` has no `==` and is
  /// replaced on every flush of a streaming reply — tens of times a second —
  /// while none of what this message carries changes between them. The words
  /// themselves reach the mirror as records; this is only the turn around
  /// them.
  final _published = <String, String>{};

  ChatController _of(String chatId) =>
      _ref.read(chatControllerProvider(chatId).notifier);

  /// The controller is held by the subscription rather than by the page: a
  /// mirror can be reading a chat this device has nothing on screen for.
  void _served() {
    final served = _hub.servedChats.value;
    for (final chatId in _watching.keys.toList()) {
      if (served.contains(chatId)) continue;
      _watching.remove(chatId)?.close();
      _published.remove(chatId);
    }
    for (final chatId in served) {
      _watching.putIfAbsent(
        chatId,
        () => _ref.listen<ChatViewState>(
          chatControllerProvider(chatId),
          (_, view) => _publish(chatId, view),
          fireImmediately: true,
        ),
      );
    }
  }

  void _publish(String chatId, ChatViewState view) {
    final asks = [
      for (final asked in view.questions)
        SyncAsk(id: asked.id, argumentsJson: asked.argumentsJson),
    ];
    final signature = [
      view.isRunning,
      view.status,
      view.retry,
      [for (final a in view.approvals) a.id],
      [for (final a in asks) a.id],
    ].join("\u0000");
    if (_published[chatId] == signature) return;
    _published[chatId] = signature;
    _hub.publishTurn(
      chatId,
      running: view.isRunning,
      approvals: view.approvals,
      asks: asks,
      status: view.status,
      retry: view.retry,
    );
  }

  @override
  void prompt(String chatId, String text) => _of(chatId).send(text);

  @override
  void resume(String chatId) => _of(chatId).resume();

  @override
  void abort(String chatId) => _of(chatId).abort();

  @override
  void approve(String chatId, String approvalId, bool allow) => _of(chatId)
      .respondApproval(
          approvalId, allow ? ApprovalResponse.allow : ApprovalResponse.deny);

  @override
  void answer(String chatId, String requestId, List<String?> answers) =>
      _of(chatId).answerQuestions(requestId, answers);

  void dispose() {
    _hub.servedChats.removeListener(_served);
    for (final subscription in _watching.values) {
      subscription.close();
    }
    _watching.clear();
    _published.clear();
  }
}

final remoteTurnDriverProvider = Provider<RemoteTurnDriver>((ref) {
  final driver = RemoteTurnDriver(ref, ref.watch(syncHubProvider));
  ref.onDispose(driver.dispose);
  return driver;
});
