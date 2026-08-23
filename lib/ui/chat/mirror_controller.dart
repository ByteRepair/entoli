import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/sync_hub.dart";
import "../../domain/chat_log.dart";
import "../../providers.dart";
import "chat_controller.dart" show ChatViewState;

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
class MirrorChatController extends Notifier<ChatViewState> {
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
    return ChatViewState(
      chat: chatFrom(mirror.state, mirror.records),
      // A mirror never runs anything itself; whether the home device is mid-
      // turn arrives with Phase 3's turn markers. Offline is the one status
      // worth saying today: stale content over no connection.
      status: hub.isChatOnline(chatId)
          ? null
          : "offline — showing what this device last had",
    );
  }
}

final mirrorChatControllerProvider = NotifierProvider.family<
    MirrorChatController, ChatViewState, String>(MirrorChatController.new);
