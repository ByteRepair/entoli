import "../../../app/approvals.dart";
import "../../../app/turn_surface.dart";
import "package:flutter/material.dart";

import "../../../domain/goal.dart" show ChatGoals;
import "../../../domain/models.dart";
import "../../../domain/room/room_state.dart";
import "../../../app/chat_controller.dart";
import "approval_banner.dart";
import "browser_strip.dart";
import "goal_strip.dart";
import "question_panel.dart";
import "resume_bar.dart";
import "running_strip.dart";
import "steer_strip.dart";

/// Everything a running turn puts on screen above whatever is used to answer
/// it: the offer to carry on an interrupted one, the chat's goal, the
/// sub-agents still going, and the commands waiting to be approved.
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
  const TurnSurface({
    super.key,
    required this.view,
    required this.notifier,
    this.onWithdrawn,
  });

  final ChatViewState view;
  final TurnDriver notifier;

  /// Where a say taken back from the turn goes: the composer it was typed in.
  /// Null where there is none, as on the voice screen.
  final ValueChanged<Draft>? onWithdrawn;

  @override
  Widget build(BuildContext context) {
    final chat = view.chat;
    final surface = TurnSurfaceModel(view);
    final restore = onWithdrawn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (surface.resume case (:final startedAt, :final notice))
          ResumeBar(
            startedAt: startedAt,
            onContinue: notifier.resume,
            notice: notice,
          ),
        if (chat != null) BrowserPrompts(chatId: chat.state.id),
        GoalStrip(goal: chat?.goal, onCommand: notifier.send),
        RunningStrip(view: view),
        SteerStrip(
          steering: view.steering,
          onQueue: notifier.queueSteer,
          onWithdraw: restore == null
              ? null
              : (id) async {
                  final said = await notifier.withdrawSteer(id);
                  if (said != null) restore(said);
                },
        ),
        for (final approval in surface.approvals)
          if (approvalAnswers(notifier, approval) case final offers)
            ApprovalBanner(
              approval: approval,
              onAllow: !offers.allow
                  ? null
                  : () => notifier.answer(approval, ApprovalResponse.allow),
              onDeny: () => notifier.answer(approval, ApprovalResponse.deny),
              onAlwaysAllowChat: !offers.always
                  ? null
                  : () => notifier.answer(
                      approval,
                      ApprovalResponse.alwaysAllowChat,
                    ),
              onAlwaysAllowProject: !offers.always
                  ? null
                  : () => notifier.answer(
                      approval,
                      ApprovalResponse.alwaysAllowProject,
                    ),
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
    final asked = TurnSurfaceModel(view).asked;
    if (asked == null) return const SizedBox.shrink();
    return QuestionPanel(
      key: ValueKey(asked.id),
      request: asked,
      onAnswered: (answers) => notifier.answerQuestions(asked.id, answers),
    );
  }
}
