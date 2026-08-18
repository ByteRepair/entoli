import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../chat_controller.dart";
import "approval_banner.dart";
import "resume_bar.dart";
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
/// The question panel is deliberately not here: the chat page swaps it for the
/// composer, because there is nothing useful to type until it is answered,
/// while the voice screen keeps the circle above it. Where it goes is the
/// page's business; that these three appear is not.
class TurnSurface extends StatelessWidget {
  const TurnSurface({super.key, required this.view, required this.notifier});

  final ChatViewState view;
  final ChatController notifier;

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
          ),
        SubAgentStrip(agents: view.runningSubAgents),
        for (final approval in view.approvals)
          ApprovalBanner(
            approval: approval,
            onAllow: () =>
                notifier.respondApproval(approval.id, ApprovalResponse.allow),
            onDeny: () => notifier.respondApproval(approval.id, ApprovalResponse.deny),
          ),
      ],
    );
  }
}
