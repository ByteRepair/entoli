import "package:flutter/material.dart";

import "../../../domain/goal.dart";
import "../../../domain/models.dart";
import "../activity/card.dart";
import "../activity/label.dart";
import "goal_strip.dart" show goalStatusIcon;

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
Future<void> openGoalMark(BuildContext context, GoalMark mark) =>
    openActivityCard(context, (page) => goalMarkCard(mark, page: page));

/// What [mark]'s drawer shows: where the goal stood after it, why, and the
/// prompt the model was given for it — the kickoff `/goal` is worded as.
ActivityCard goalMarkCard(GoalMark mark, {bool page = false}) => ActivityCard(
  title: goalChangeLabel(mark.change),
  icon: goalChangeIcon(mark.change),
  status: (
    // An answer changed nothing, so there is no "now" to name: saying
    // "no goal" over a goal that still stands would be the one lie this row
    // could tell.
    text: switch (goalStatusAfter(mark.change)) {
      final status? => "Now: ${status.name}",
      null when mark.change == GoalChange.answered => "No change",
      null => "Now: no goal",
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

/// A change's icon: the status it leaves, but for the two that say how it
/// got there.
IconData goalChangeIcon(GoalChange change) => switch (change) {
  GoalChange.resumed => Icons.play_circle_outline,
  GoalChange.cleared => Icons.highlight_off,
  // Nothing moved; the icon says the command was heard and answered.
  GoalChange.answered => Icons.info_outline,
  _ => goalStatusIcon(goalStatusAfter(change)!),
};
