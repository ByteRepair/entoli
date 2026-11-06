import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/goal.dart";
import "../../../domain/models.dart";
import "../../widgets/liquid_glass.dart" show liquidGlassProvider;
import "../activity/card.dart";
import "../activity/label.dart";

/// A change to the chat's goal, where the log says it happened: one activity
/// label in the conversation — "Goal set", "Goal paused", "Goal met" — that
/// opens a drawer with the goal's prompt and where the goal stood after it.
/// Drawn off a [GoalMark], which `replayTree` keeps from the `goal` records,
/// so a restart draws the same rows. See "Goals" in `lib/domain/AGENTS.md`.
class GoalMarkRow extends StatelessWidget {
  const GoalMarkRow({super.key, required this.mark});

  final GoalMark mark;

  @override
  Widget build(BuildContext context) => Padding(
    // The reply's gutter, so the label sits where a reply's labels do.
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: ActivityLabel(
      icon: goalChangeIcon(mark.change),
      text: "${goalChangeLabel(mark.change)}: ${mark.objective}",
      isError: mark.change == GoalChange.blocked,
      onTap: () => openGoalMark(context, mark),
    ),
  );
}

/// [mark]'s drawer: a sheet, or a page under the native shell, as every
/// activity's is.
Future<void> openGoalMark(BuildContext context, GoalMark mark) {
  final page = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(liquidGlassProvider).on;
  Widget card(BuildContext _) => goalMarkCard(mark, page: page);
  if (page) {
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: card));
  }
  return showActivityCard<void>(context, card);
}

/// What [mark]'s drawer shows: where the goal stood after it, why, and the
/// prompt the model was given for it — the kickoff `/goal` is worded as.
ActivityCard goalMarkCard(GoalMark mark, {bool page = false}) => ActivityCard(
  title: goalChangeLabel(mark.change),
  icon: goalChangeIcon(mark.change),
  status: (
    text: switch (mark.change) {
      GoalChange.set || GoalChange.resumed => "Now: active",
      GoalChange.paused => "Now: paused",
      GoalChange.cleared => "Now: no goal",
      GoalChange.met => "Now: met",
      GoalChange.blocked => "Now: blocked",
    },
    isError: mark.change == GoalChange.blocked,
  ),
  sections: [
    (label: "Objective", body: mark.objective, isError: false),
    (
      label: switch (mark.change) {
        GoalChange.met || GoalChange.blocked => "Reviewer",
        _ => "Why",
      },
      body: mark.reason,
      isError: false,
    ),
    (label: "Goal prompt", body: goalKickoff(mark.objective), isError: false),
  ],
  page: page,
);

IconData goalChangeIcon(GoalChange change) => switch (change) {
  GoalChange.set => Icons.track_changes,
  GoalChange.resumed => Icons.play_circle_outline,
  GoalChange.paused => Icons.pause_circle_outline,
  GoalChange.cleared => Icons.highlight_off,
  GoalChange.met => Icons.check_circle_outline,
  GoalChange.blocked => Icons.block,
};
