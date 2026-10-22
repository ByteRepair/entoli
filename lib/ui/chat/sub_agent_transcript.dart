import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/chat_log.dart";
import "../../domain/chat_repository.dart";
import "../../domain/models.dart";
import "../../domain/sub_agent_log.dart";
import "../../providers.dart";
import "mirror_controller.dart" show chatViewProvider;
import "widgets/activity_label.dart" show LiveMessage;

/// Which sub-agent: the chat, and the `task` call that spawned it.
typedef SubAgentCall = ({String chatId, String callId});

/// A sub-agent's transcript as the `task` drawer draws it: the one message a
/// run is, and whether its log has closed.
typedef SubAgentTranscript = ({Message? message, bool ended});

/// One sub-agent's transcript while a drawer has it open: read whole, then
/// grown by each append — off the repository here, off the hub for a chat
/// mirrored from a paired device. The same records either way, so what the
/// drawer draws is the log rather than a second account of the run.
class SubAgentTranscriptNotifier extends Notifier<SubAgentTranscript> {
  SubAgentTranscriptNotifier(this.call);

  final SubAgentCall call;

  List<ChatRecord> _records = const [];

  @override
  SubAgentTranscript build() {
    final (:chatId, :callId) = call;
    if (ref.watch(isMirroredChatProvider(chatId))) {
      final hub = ref.watch(syncHubProvider);
      hub.followSubAgent(chatId, callId);
      final sub = hub.subAgentUpdates.where((u) => u == call).listen(
          (_) => _set(hub.subAgentRecords(chatId, callId) ?? const []));
      ref.onDispose(() {
        sub.cancel();
        hub.unfollowSubAgent(chatId, callId);
      });
      _records = hub.subAgentRecords(chatId, callId) ?? const [];
      return _of(_records);
    }
    final repo = ref.watch(chatRepositoryProvider);
    final sub = repo.subAgentAppends
        .where((a) => a.chatId == chatId && a.callId == callId)
        .listen((a) {
      final grown = growTranscript(_records, a.from, a.records);
      grown == null ? unawaited(_read(repo)) : _set(grown);
    });
    ref.onDispose(sub.cancel);
    unawaited(_read(repo));
    return _of(const []);
  }

  /// A read is a snapshot from when it was asked, so one that lands behind
  /// appends already applied is older than what is held and is dropped.
  Future<void> _read(ChatRepository repo) async {
    final records = await repo.subAgentRecords(call.chatId, call.callId);
    if (ref.mounted && records.length >= _records.length) _set(records);
  }

  void _set(List<ChatRecord> records) {
    _records = records;
    if (ref.mounted) state = _of(records);
  }

  static SubAgentTranscript _of(List<ChatRecord> records) => (
        message: replay(records).lastOrNull,
        ended: records.lastOrNull is TurnEndRecord,
      );
}

final subAgentTranscriptProvider = NotifierProvider.autoDispose
    .family<SubAgentTranscriptNotifier, SubAgentTranscript, SubAgentCall>(
        SubAgentTranscriptNotifier.new);

/// The transcript as a message a drawer can follow, for the labels inside it.
/// Live while its log is open and its chat has a turn running: a log left
/// open by a killed process is not a sub-agent still going.
final subAgentLiveProvider =
    Provider.autoDispose.family<LiveMessage, SubAgentCall>((ref, call) {
  final transcript = ref.watch(subAgentTranscriptProvider(call));
  final running =
      ref.watch(chatViewProvider(call.chatId).select((v) => v.isRunning));
  return (
    message: transcript.message,
    shellOutput: null,
    running: running && !transcript.ended,
  );
});
