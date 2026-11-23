import "dart:typed_data";

import "package:entoli_core/transcript/activity.dart" show LiveMessage;
import "package:entoli_core/transcript/host.dart";
import "package:entoli_core/model/config.dart";
import "package:entoli_core/model/agent_face.dart";
import "package:entoli_core/model/chat_log.dart" show replay;
import "package:entoli_core/model/chat_store.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/plan.dart";
import "package:entoli_core/model/room/room_state.dart" show ChatViewState;
import "package:entoli_core/model/shell_job.dart" show ShellJob;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

/// A shared chat as the transcript's host: the one chat the link unpacked,
/// read from its store and never running. It carries no agent pictures, and
/// a job in it ended where it was shared.
class SharedChatHost implements TranscriptHost {
  SharedChatHost(this.chat, {required this.store, required this.config})
    : _view = Provider((_) => ChatViewState(chat: chat));

  final Chat chat;
  final ChatStore store;
  final AppConfig config;

  final Provider<ChatViewState> _view;

  late final _plan = FutureProvider<List<PlanSection>?>((ref) async {
    final sections = planSectionsFrom(await store.readPlan(chat.state.id));
    return sections.isEmpty ? null : sections;
  });

  late final _subAgent = FutureProvider.family<Message?, String>(
    (ref, callId) async =>
        replay(await store.readSubAgentRecords(chat.state.id, callId))
            .lastOrNull,
  );

  late final _resource = FutureProvider.family<Uint8List?, String>(
    (ref, resource) => store.readResource(chat.state.id, resource),
  );

  late final _subAgentLive = Provider.family<LiveMessage, String>(
    (ref, callId) => (
      message: ref.watch(_subAgent(callId)).value,
      shellOutput: null,
      running: false,
    ),
  );

  static final _noFace = Provider<AsyncValue<AgentFace?>>(
    (_) => const AsyncData(null),
  );

  static final _noLog = Provider<AsyncValue<String>>(
    (_) => const AsyncData(""),
  );

  @override
  ProviderListenable<ChatViewState> view(String chatId) => _view;

  @override
  ProviderListenable<AsyncValue<List<PlanSection>?>> plan(String chatId) =>
      _plan;

  @override
  ProviderListenable<LiveMessage> subAgent(SubAgentCall call) =>
      _subAgentLive(call.callId);

  @override
  ProviderListenable<AsyncValue<AgentFace?>> face({
    String? project,
    required String name,
  }) => _noFace;

  @override
  ProviderListenable<AsyncValue<Uint8List?>> resource(
    String chatId,
    String resource,
  ) => _resource(resource);

  @override
  ProviderListenable<AsyncValue<String>> jobLog(String chatId, ShellJob job) =>
      _noLog;

  @override
  Future<void> stopJob(String chatId, int jobId) async {}

  @override
  String workspaceDir(String chatId, {String? project}) =>
      config.workspaceDir(chatId, project: project);
}
