import "package:flutter/material.dart";

import "../../../app/transcript/transcript.dart" show GoalRow;
import "../activity/card.dart";
import "../activity/glyphs.dart";
import "../activity/label.dart";

/// A change to the chat's goal, where the log says it happened: one activity
/// label in the conversation that opens the goal's detail — both the core's
/// ([GoalRow]). Drawn off a `GoalMark`, which `replayTree` keeps from the
/// `goal` records, so a restart draws the same rows. See "Goals" in
/// `lib/domain/AGENTS.md`.
class GoalMarkRow extends StatelessWidget {
  const GoalMarkRow({super.key, required this.row});

  final GoalRow row;

  @override
  Widget build(BuildContext context) => Padding(
    // The reply's gutter, so the label sits where a reply's labels do.
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: ActivityLabel(
      icon: iconOf(row.glyph),
      text: row.label,
      isError: row.isError,
      onTap: () => openGoalMark(context, row),
    ),
  );
}

/// [row]'s detail: a sheet, or a page under the native shell, as every
/// activity's is.
Future<void> openGoalMark(BuildContext context, GoalRow row) =>
    openActivityCard(
      context,
      (page) => ActivityCard(detail: row.detail, page: page),
    );
