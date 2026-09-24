import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/sync_hub.dart";
import "../../domain/ask.dart";
import "../../domain/chat_log.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "chat_controller.dart" show ChatViewState, TurnDriver;

/// The controller a mirrored chat is read through — the counterpart
/// [ChatController] would have been if it read from the wire instead of the
/// store. Deliberately its own family rather than an arm of
/// [chatControllerProvider]: that one's build hits the local disk and wires
/// appends into the repository, both of which are exactly wrong for a chat
/// whose home device is somewhere else.
///
/// State comes from [SyncHub]'s mirror of the peer: records replay through
/// the same pure `chatFrom`/`replayTree` a reload uses, so what the page
/// draws is the log, not a second rendering of it.
///
/// It is a [TurnDriver] as well, and none of that runs anything here. Every
/// verb goes over the wire to the chat's home device, which runs it through
/// its own [ChatController] — and that device refuses the lot unless this one
/// holds the chat, so a page drawing a composer is not what permits a turn.
class MirrorChatController extends Notifier<ChatViewState>
    implements TurnDriver {
  MirrorChatController(this.chatId);

  final String chatId;
  StreamSubscription<String>? _sub;

  @override
  ChatViewState build() {
    final hub = ref.watch(syncHubProvider);
    hub.followChat(chatId);
    ref.onDispose(() => hub.unfollowChat(chatId));
    _sub = hub.mirrorUpdates.where((id) => id == chatId).listen((_) {
      if (ref.mounted) state = _viewOf(hub);
    });
    ref.onDispose(() => _sub?.cancel());
    return _viewOf(hub);
  }

  ChatViewState _viewOf(SyncHub hub) {
    final mirror = hub.mirror(chatId);
    if (mirror == null) return ChatViewState();
    final online = hub.isChatOnline(chatId);
    return ChatViewState(
      chat: chatFrom(mirror.state, mirror.records),
      isRunning: online && mirror.running,
      // A mirror sees one turn, the home device's — keyed by that turn's
      // own reply, the shape the state asks for.
      approvals: online
          ? {"mirror": mirror.approvals}
          : const {},
      // Rebuilt from the call's own arguments rather than from a second
      // encoding of the questions — the same string the home device read.
      questions: online
          ? {
              "mirror": [
                for (final asked in mirror.asks)
                  AskRequest(
                    id: asked.id,
                    questions: askQuestionsFrom(asked.argumentsJson),
                    argumentsJson: asked.argumentsJson,
                  ),
              ]
            }
          : const {},
      retry: online ? mirror.retry : null,
      // Offline outranks whatever the turn was last saying: a status line from
      // before the connection dropped is a turn claiming to still be alive,
      // and an approval nothing can carry the answer to is worse than none.
      status: online
          ? mirror.status
          : "offline — showing what this device last had",
    );
  }

  SyncHub get _hub => ref.read(syncHubProvider);

  /// Attachments are not sent from a mirror: their bytes would have to cross
  /// to be saved under a chat on the other side, which is a phase of its own.
  @override
  Future<void> send(String text, {List<Attachment> attachments = const []}) =>
      _hub.sendRemotePrompt(chatId, text);

  @override
  Future<void> resume() => _hub.resumeRemote(chatId);

  @override
  Future<void> abort() => _hub.abortRemote(chatId);

  @override
  bool get rulesWritable => false;

  @override
  Future<void> respondApproval(String approvalId, ApprovalResponse r,
          {ToolApproval? approval}) =>
      _hub
      .respondRemoteApproval(
          chatId, approvalId,
          r == ApprovalResponse.allow ||
              r == ApprovalResponse.alwaysAllowChat ||
              r == ApprovalResponse.alwaysAllowProject);

  @override
  Future<void> answerQuestions(String requestId, List<String?> answers) =>
      _hub.answerRemoteQuestions(chatId, requestId, answers);
}

final mirrorChatControllerProvider = NotifierProvider.family<
    MirrorChatController, ChatViewState, String>(MirrorChatController.new);

/// Who may type into a mirrored chat. Its own state rather than a field on
/// [ChatViewState] because it is not about the turn — a chat with nothing
/// running still has a holder, and a local chat has no such question.
class MirrorControl {
  const MirrorControl({this.holder, this.held = false, this.asking = false});

  /// The device id the home end says has it, or null for nobody. Always the
  /// home device's answer: taking control is a request, not a decision.
  final String? holder;

  /// Whether that is this device.
  final bool held;

  /// Asked for and not yet answered — what the button says while it waits.
  final bool asking;

  /// Somebody else has it, which is the one case with nothing to offer.
  bool get takenByAnother => holder != null && !held;
}

class MirrorControlNotifier extends Notifier<MirrorControl> {
  MirrorControlNotifier(this.chatId);

  final String chatId;
  StreamSubscription<String>? _sub;

  @override
  MirrorControl build() {
    final hub = ref.watch(syncHubProvider);
    _sub = hub.mirrorUpdates.where((id) => id == chatId).listen((_) {
      if (ref.mounted) state = _of(hub);
    });
    ref.onDispose(() => _sub?.cancel());
    return _of(hub);
  }

  MirrorControl _of(SyncHub hub) => MirrorControl(
        holder: hub.mirror(chatId)?.controlHolder,
        held: hub.holdsControl(chatId),
        asking: hub.isRequestingControl(chatId),
      );

  Future<void> take() => ref.read(syncHubProvider).requestControl(chatId);

  Future<void> release() => ref.read(syncHubProvider).releaseControl(chatId);
}

final mirrorControlProvider = NotifierProvider.family<MirrorControlNotifier,
    MirrorControl, String>(MirrorControlNotifier.new);
