import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/agent_backend.dart" show taskToolName;
import "../../../domain/room/room_state.dart" show ChatViewState;
import "../../../domain/tool_arg.dart";
import "../mirror_controller.dart" show chatViewProvider;
import "../sub_agent_transcript.dart" show subAgentLiveProvider;
import "../activity/activity.dart";
import "../activity/card.dart" show ActivitySource, liveMessageOf;
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
  RunView view(WidgetRef ref, Run run) => SubAgentActivity(
    agent: stringArg(run.call?.argumentsJson, "agent") ?? "task",
  ).view(ref, run);
}

/// A sub-agent's run: the sub-agent that ran, and behind the drawer its own
/// transcript as it is written — the same labels a reply has — with the text
/// it returned standing in where there is no transcript to show. Drawn for
/// the call in the reply and for the sub-agent's pill alike; the prompt is
/// the call's where the call is to hand, [prompt] until then.
class SubAgentActivity extends LabelledActivity {
  const SubAgentActivity({required this.agent, this.prompt = ""});

  final String agent;
  final String prompt;

  @override
  RunView view(WidgetRef ref, Run run) {
    final result = run.result;
    final failed = (result?.returnCode ?? 0) != 0;
    final prompt = stringArg(run.call?.argumentsJson, "prompt") ?? this.prompt;
    return RunView(
      icon: Icons.account_tree_outlined,
      label: result == null
          ? "Running sub-agent @$agent"
          : "Sub-agent @$agent ${failed ? "failed" : "finished"}",
      isError: failed,
      busy: run.going && result == null,
      drawer: (ref) {
        final sub = (chatId: run.chatId, callId: run.callId!);
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
}

/// The sub-agents still running, a pill each, opening the drawer its label in
/// the reply opens and following the turn the same way.
List<RunningThing> subAgentsRunning(
  WidgetRef ref,
  ChatViewState view,
  String chatId,
) => [
  for (final MapEntry(key: replyId, value: agents)
      in view.runningSubAgents.entries)
    for (final agent in agents)
      RunningThing(
        group: "sub-agent",
        label: "@${agent.agent}",
        tooltip: "Sub-agent @${agent.agent}",
        // The event's prompt is cut for the pill; the call, followed
        // once it is written, has all of it.
        open: (context) =>
            SubAgentActivity(agent: agent.agent, prompt: agent.prompt).open(
              context,
              Run(chatId: chatId, callId: agent.id),
              source: chatViewProvider(
                chatId,
              ).select((v) => liveMessageOf(v, replyId)),
            ),
      ),
];
