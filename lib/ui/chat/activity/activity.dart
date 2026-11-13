import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../../app/running.dart" show OpensDetail;
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
  Widget build(BuildContext context) => switch (node) {
    final LabelNode label => LabelNodeView(
      label,
      onTap: () => openActivityDetail(context, node),
    ),
    final DiffNode diff => DiffNodeView(
      diff,
      onTap: () => openActivityDetail(context, node),
    ),
    final PlanNode plan => PlanNodeView(plan),
    final OutputNode output => OutputNodeView(output),
  };
}

/// Opens [node]'s detail: a sheet, or a page under the native shell. It
/// follows the run's message through [source], or the [ActivitySource]
/// above [context]; with neither it shows the run as it was opened.
Future<void> openActivityDetail(
  BuildContext context,
  ActivityNode node, {
  ProviderListenable<LiveMessage>? source,
}) => openRunDetail(
  context,
  OpensDetail(
    node.activity,
    node.run,
    source: source ?? ActivitySource.of(context),
  ),
);

/// Opens [opens]'s detail: a node's, or a running pill's job or sub-agent.
Future<void> openRunDetail(BuildContext context, OpensDetail opens) =>
    openActivityCard(context, (page) => _DetailCard(opens: opens, page: page));

class _DetailCard extends ConsumerWidget {
  const _DetailCard({required this.opens, required this.page});

  final OpensDetail opens;
  final bool page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = opens.detail(WidgetReader(ref));
    if (detail == null) return const SizedBox.shrink();
    final nested = detail.transcript;
    return ActivityCard(
      detail: detail,
      page: page,
      below: nested == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 12),
              // Its own source, so a label in the transcript opens a detail
              // that follows the sub-agent rather than the parent's reply.
              child: ActivitySource(
                live: nested.source,
                child: ref.watch(nestedTranscriptViewProvider)(nested),
              ),
            ),
    );
  }
}

/// Draws a transcript held inside a detail — a sub-agent's reply — the way
/// the conversation draws a message. A detail is inside a message and a
/// message is made of details' nodes, so the bubble is bound at the root
/// (`main`) rather than imported here.
final nestedTranscriptViewProvider =
    Provider<Widget Function(NestedTranscript)>(
      (ref) => throw UnimplementedError("bound where the app is assembled"),
    );

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
