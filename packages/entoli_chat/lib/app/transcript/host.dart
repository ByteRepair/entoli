import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../domain/agent_face.dart";
import "../../domain/plan.dart" show PlanSection;
import "../../domain/room/room_state.dart" show ChatViewState;
import "../../domain/shell_job.dart" show ShellJob;
import "activity.dart" show LiveMessage;

/// Which sub-agent: the chat, and the `task` call that spawned it.
typedef SubAgentCall = ({String chatId, String callId});

/// What drawing a conversation reads about its chat beyond the messages it is
/// handed, and the one thing it does to it. The transcript depends on this
/// and on nothing of the app around it, so it is drawn wherever something
/// can answer: the app binds its controllers, store and backend
/// (`AppTranscriptHost`), the share viewer the chat it unpacked.
abstract interface class TranscriptHost {
  /// The chat as it stands, which a background job and an open detail follow.
  ProviderListenable<ChatViewState> view(String chatId);

  /// The chat's `PLAN.md`, parsed; null where it has none.
  ProviderListenable<AsyncValue<List<PlanSection>?>> plan(String chatId);

  /// Sub-agent [call]'s transcript, as a detail follows it.
  ProviderListenable<LiveMessage> subAgent(SubAgentCall call);

  /// The face of member [name] in [project]; null where it has none.
  ProviderListenable<AsyncValue<AgentFace?>> face({
    String? project,
    required String name,
  });

  /// The bytes of what was attached as [resource].
  ProviderListenable<AsyncValue<Uint8List?>> resource(
    String chatId,
    String resource,
  );

  /// The end of running [job]'s log as it grows.
  ProviderListenable<AsyncValue<String>> jobLog(String chatId, ShellJob job);

  Future<void> stopJob(String chatId, int jobId);

  /// Where chat [chatId]'s commands ran: a job's whole log is there, and the
  /// viewer's Files open it.
  String workspaceDir(String chatId, {String? project});
}

final transcriptHostProvider = Provider<TranscriptHost>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);
