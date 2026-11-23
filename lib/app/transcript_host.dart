import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "package:entoli_chat/domain/agent_face.dart";
import "package:entoli_chat/domain/plan.dart" show PlanSection;
import "package:entoli_chat/domain/room/room_state.dart" show ChatViewState;
import "package:entoli_chat/domain/shell_job.dart" show ShellJob;
import "../providers.dart";
import "mirror_controller.dart" show chatViewProvider;
import "plan.dart" show planProvider;
import "sub_agent_transcript.dart" show subAgentLiveProvider;
import "package:entoli_chat/app/transcript/activity.dart" show LiveMessage;
import "package:entoli_chat/app/transcript/host.dart";

/// The conversation's host in the app: this device's controller or a paired
/// device's mirror, the store and the backend.
class AppTranscriptHost implements TranscriptHost {
  AppTranscriptHost(this._ref);

  final Ref _ref;

  @override
  ProviderListenable<ChatViewState> view(String chatId) =>
      chatViewProvider(chatId);

  @override
  ProviderListenable<AsyncValue<List<PlanSection>?>> plan(String chatId) =>
      planProvider(chatId);

  @override
  ProviderListenable<LiveMessage> subAgent(SubAgentCall call) =>
      subAgentLiveProvider(call);

  @override
  ProviderListenable<AsyncValue<AgentFace?>> face({
    String? project,
    required String name,
  }) => agentPictureProvider((project: project, name: name));

  @override
  ProviderListenable<AsyncValue<Uint8List?>> resource(
    String chatId,
    String resource,
  ) => attachmentBytesProvider((chatId: chatId, resource: resource));

  @override
  ProviderListenable<AsyncValue<String>> jobLog(String chatId, ShellJob job) =>
      _jobLogProvider((chatId: chatId, job: job));

  @override
  Future<void> stopJob(String chatId, int jobId) =>
      _ref.read(agentBackendProvider).jobsOf(chatId).stop(jobId);

  @override
  String workspaceDir(String chatId, {String? project}) =>
      _ref.read(appConfigProvider).workspaceDir(chatId, project: project);
}

final _jobLogProvider = StreamProvider.autoDispose
    .family<String, ({String chatId, ShellJob job})>(
      (ref, of) =>
          ref.watch(agentBackendProvider).jobsOf(of.chatId).log(of.job),
    );
