import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/agent_backend.dart" show taskToolName;
import "../../../domain/models.dart" show ToolCall;
import "../../../domain/room/room_state.dart" show ChatViewState;
import "../../../domain/tool_arg.dart";
import "../mirror_controller.dart" show chatViewProvider;
import "../sub_agent_transcript.dart" show subAgentLiveProvider;
import "../widgets/activity_label.dart"
    show ActivitySource, Run, RunView, liveMessageOf, showRunCard, toolCallIn;
import "../widgets/message_bubble.dart" show MessageBubble;
import "../widgets/running_pill.dart" show RunningSource, RunningThing;
import "tool_ui.dart";

/// A sub-agent's call: the sub-agent that ran, and behind the drawer its own
/// transcript as it is written — the same labels a reply has — with the text
/// it returned standing in where there is no transcript to show. Reads the
/// agent name and prompt out of the call's arguments.
class TaskUI extends ToolUI {
  const TaskUI();

  @override
  String get tool => taskToolName;

  @override
  String get spoken => "Ran a sub-agent";

  @override
  RunView view(WidgetRef ref, Run run) {
    final result = run.result;
    final agent = stringArg(run.call?.argumentsJson, "agent") ?? "task";
    final prompt = stringArg(run.call?.argumentsJson, "prompt") ?? "";
    final failed = (result?.returnCode ?? 0) != 0;
    final sub = (chatId: run.chatId, callId: run.callId);
    final live = run.card ? ref.watch(subAgentLiveProvider(sub)) : null;
    final transcript = live?.message;
    final drawn = transcript != null && transcript.parts.isNotEmpty;
    return RunView(
      icon: Icons.account_tree_outlined,
      label: result == null
          ? "Running sub-agent @$agent"
          : "Sub-agent @$agent ${failed ? "failed" : "finished"}",
      isError: failed,
      title: "Sub-agent @$agent",
      live: run.live,
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
                  isWaiting: live!.running,
                ),
              ),
            ),
    );
  }
}

/// The sub-agents still running, a pill each, opening the drawer its label in
/// the reply opens and following the turn the same way.
class SubAgentsRunning extends RunningSource {
  const SubAgentsRunning();

  @override
  List<RunningThing> things(WidgetRef ref, ChatViewState view, String chatId) => [
        for (final MapEntry(key: replyId, value: agents)
            in view.runningSubAgents.entries)
          for (final agent in agents)
            RunningThing(
              group: "sub-agent",
              label: "@${agent.agent}",
              tooltip: "Sub-agent @${agent.agent}",
              open: (context) {
                final reply =
                    view.chat?.messages.where((m) => m.id == replyId).firstOrNull;
                // The event's prompt is cut for the pill; the call, once it
                // is written, has all of it.
                final call = toolCallIn(reply, agent.id) ??
                    ToolCall(
                        id: agent.id,
                        name: taskToolName,
                        argumentsJson: jsonEncode(
                            {"agent": agent.agent, "prompt": agent.prompt}));
                showRunCard(
                  context,
                  view: const TaskUI().view,
                  run: Run(chatId: chatId, callId: agent.id, call: call),
                  source: chatViewProvider(chatId)
                      .select((v) => liveMessageOf(v, replyId)),
                );
              },
            ),
      ];
}
