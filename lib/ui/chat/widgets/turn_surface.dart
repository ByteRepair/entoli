import "package:flutter/material.dart";

import "../../../data/builtin/directory_tools.dart";
import "../../../domain/models.dart";
import "../../../domain/room/room_state.dart";
import "../chat_controller.dart";
import "approval_banner.dart";
import "browser_strip.dart";
import "question_panel.dart";
import "resume_bar.dart";
import "steer_strip.dart";
import "sub_agent_strip.dart";

/// Everything a running turn puts on screen above whatever is used to answer
/// it: the offer to carry on an interrupted one, the sub-agents still going,
/// and the commands waiting to be approved.
///
/// Shared because voice mode draws the same turn. The widgets were shared from
/// the start and the *wiring* was not, which is how the voice screen shipped
/// without a `ResumeBar` — the one screen where a turn is most likely to be cut
/// off, since talking over a reply aborts it.
///
/// The question panel is [TurnQuestions], beside this rather than in it: where it
/// goes differs — the chat page swaps it for the composer, because there is
/// nothing useful to type until it is answered, while the voice screen keeps
/// the circle above it — but how it is wired does not.
class TurnSurface extends StatelessWidget {
  const TurnSurface(
      {super.key, required this.view, required this.notifier, this.onWithdrawn});

  final ChatViewState view;
  final TurnDriver notifier;

  /// Where a say taken back from the turn goes: the composer it was typed in.
  /// Null where there is none, as on the voice screen.
  final void Function(String text, List<Attachment> attachments)? onWithdrawn;

  @override
  Widget build(BuildContext context) {
    final chat = view.chat;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Only while nothing is running: the turn being carried on is the one
        // at the end, so the offer and the work are never both on screen.
        if (chat != null && chat.unfinished && !view.isRunning)
          ResumeBar(
            startedAt: chat.messages.last.createdAt,
            onContinue: notifier.resume,
            notice: view.unfinishedNotice,
          ),
        for (final agents in view.runningSubAgents.values)
          SubAgentStrip(agents: agents),
        SteerStrip(
          steering: view.steering,
          onQueue: notifier.queueSteer,
          onWithdraw: (id) async {
            final said = await notifier.withdrawSteer(id);
            if (said != null) onWithdrawn?.call(said.text, said.attachments);
          },
        ),
        // Not turn-scoped like the strips above: the tab outlives the turn
        // that opened it, so the chip shows for as long as the tab is open.
        if (chat != null) BrowserStrip(chatId: chat.state.id),
        for (final approvals in view.approvals.values)
          for (final approval in approvals)
            ApprovalBanner(
              approval: approval,
              // A mirrored chat keeps it: with no always answers there,
              // Deny would be all that was left.
              onAllow: notifier.rulesWritable &&
                      approval.toolName == addDirectoryName
                  ? null
                  : () => notifier.respondApproval(
                      approval.id, ApprovalResponse.allow),
              onDeny: () => notifier.respondApproval(approval.id, ApprovalResponse.deny),
              // A re-prompt with no path to grant has nothing to persist.
              onAlwaysAllowChat: !notifier.rulesWritable ||
                      approval.rerun && approval.deniedDirs.isEmpty
                  ? null
                  : () => notifier.respondApproval(approval.id,
                      ApprovalResponse.alwaysAllowChat, approval: approval),
              onAlwaysAllowProject: !notifier.rulesWritable ||
                      approval.rerun && approval.deniedDirs.isEmpty
                  ? null
                  : () => notifier.respondApproval(approval.id,
                      ApprovalResponse.alwaysAllowProject, approval: approval),
            ),
      ],
    );
  }
}

/// What the turn is waiting to be told. Its own widget rather than five lines
/// written out at each page, which is the wiring [TurnSurface] exists to stop
/// being copied; only *where* it is drawn is the page's business.
class TurnQuestions extends StatelessWidget {
  const TurnQuestions({super.key, required this.view, required this.notifier});

  final ChatViewState view;
  final TurnDriver notifier;

  @override
  Widget build(BuildContext context) {
    // One panel, the first turn waiting on answers: a room with two asking
    // is a round that misfired — nobody answers two panels at once, and the
    // second question is still there when the first is answered.
    final asked = view.questions.values.expand((q) => q).first;
    return QuestionPanel(
      key: ValueKey(asked.id),
      request: asked,
      onAnswered: (answers) => notifier.answerQuestions(asked.id, answers),
    );
  }
}
