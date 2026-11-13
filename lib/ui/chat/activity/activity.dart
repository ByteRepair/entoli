import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/settings/spec.dart" show WidgetReader;
import "../../../app/transcript/activity.dart";
import "card.dart";
import "nodes.dart";

/// An activity's node as the Flutter frontend draws it, one widget per kind
/// of node. Built from the core's node and nothing else, so what a label
/// says and when it spins are the core's.
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

/// [activity] for [run], its node built here: an activity drawn on its own,
/// outside a message's layout.
class ActivityRunView extends ConsumerWidget {
  const ActivityRunView({super.key, required this.activity, required this.run});

  final Activity activity;
  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ActivityNodeView(activity.node(WidgetReader(ref), run));
}
