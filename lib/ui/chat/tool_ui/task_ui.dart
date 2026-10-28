import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/agent_backend.dart" show taskToolName;
import "../../../domain/room/room_state.dart" show ChatViewState;
import "../../../domain/tool_arg.dart";
import "../mirror_controller.dart" show chatViewProvider;
import "../sub_agent_transcript.dart" show subAgentLiveProvider;
import "../widgets/activity_label.dart"
    show ActivitySource, Run, RunDrawer, RunView, liveMessageOf, showRunCard;
import "../widgets/message_bubble.dart" show MessageBubble;
import "../widgets/running_pill.dart" show RunningThing;
import "tool_ui.dart";

/// A sub-agent's call, read from the call's own arguments.
class TaskUI extends ToolUI {
  const TaskUI();

  @override
  String get tool => taskToolName;

  @override
  String get spoken => "Ran a sub-agent";

  @override
  RunView view(WidgetRef ref, Run run) => subAgentView(run,
      agent: stringArg(run.call?.argumentsJson, "agent") ?? "task",
      prompt: stringArg(run.call?.argumentsJson, "prompt") ?? "");
}

/// A sub-agent's run: the sub-agent that ran, and behind the drawer its own
/// transcript as it is written — the same labels a reply has — with the text
/// it returned standing in where there is no transcript to show.
RunView subAgentView(Run run, {required String agent, required String prompt}) {
  final result = run.result;
  final failed = (result?.returnCode ?? 0) != 0;
  return RunView(
    icon: Icons.account_tree_outlined,
    label: result == null
        ? "Running sub-agent @$agent"
        : "Sub-agent @$agent ${failed ? "failed" : "finished"}",
    isError: failed,
    drawer: (ref) {
      final sub = (chatId: run.chatId, callId: run.callId);
      final live = ref.watch(subAgentLiveProvider(sub));
      final transcript = live.message;
      final drawn = transcript != null && transcript.parts.isNotEmpty;
      return RunDrawer(
        title: "Sub-agent @$agent",
        sections: [
          (label: "Prompt", body: prompt, isError: false),
          // The transcript's text joined, so left out where it is drawn.
          if (!drawn) (label: "Output", body: result?.output, isError: false),
          (label: "Error", body: result?.exceptionInfo, isError: true),
        ],
        below: !drawn
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 12),
                // Its own source, so a label in the transcript opens a drawer
                // that follows the sub-agent rather than the parent's reply.
                child: ActivitySource(
                  live: subAgentLiveProvider(sub),
                  child: MessageBubble(
                    chatId: run.chatId,
                    message: transcript,
                    isWaiting: live.running,
                  ),
                ),
              ),
      );
    },
  );
}

/// The sub-agents still running, a pill each, opening the drawer its label in
/// the reply opens and following the turn the same way.
List<RunningThing> subAgentsRunning(
        WidgetRef ref, ChatViewState view, String chatId) =>
    [
      for (final MapEntry(key: replyId, value: agents)
          in view.runningSubAgents.entries)
        for (final agent in agents)
          RunningThing(
            group: "sub-agent",
            label: "@${agent.agent}",
            tooltip: "Sub-agent @${agent.agent}",
            open: (context) => showRunCard(
              context,
              // The event's prompt is cut for the pill; the call, followed
              // once it is written, has all of it.
              view: (ref, run) => subAgentView(run,
                  agent: agent.agent,
                  prompt: stringArg(run.call?.argumentsJson, "prompt") ??
                      agent.prompt),
              run: Run(chatId: chatId, callId: agent.id),
              source: chatViewProvider(chatId)
                  .select((v) => liveMessageOf(v, replyId)),
            ),
          ),
    ];
