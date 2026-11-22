import "package:flutter/material.dart";

import "../../../app/transcript/activity.dart";
import "card.dart";
import "nodes.dart";

/// An activity's node, one widget per kind of node. Built from the core's
/// node and nothing else, so what a label says and when it spins are the
/// core's.
class ActivityNodeView extends StatelessWidget {
  const ActivityNodeView(this.node, {super.key});

  final ActivityNode node;

  @override
  Widget build(BuildContext context) {
    // What pressing it opens is the node's; it follows the message above.
    void open() =>
        node.open(ContextHandOff(context), source: ActivitySource.of(context));
    return switch (node) {
      final LabelNode label => LabelNodeView(label, onTap: open),
      final DiffNode diff => DiffNodeView(diff, onTap: open),
      final PlanNode plan => PlanNodeView(plan, onTap: open),
      final OutputNode output => OutputNodeView(output, onTap: open),
    };
  }
}
