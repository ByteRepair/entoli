import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../transcript/host.dart";
import "../../model/plan.dart";
import "../widgets/page_bar.dart";
import "widgets/plan_view.dart";

/// Open [chatId]'s plan: the app bar's button, the plan card's and the app's
/// Chat menu.
void openPlan(BuildContext context, String chatId) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => PlanPage(chatId: chatId)));

/// A chat's plan: how far it has got, and every task under its heading
/// with whether it is done, each opening to the plan written for it. It
/// follows the turn, the host reading the file again as it grows.
class PlanPage extends ConsumerWidget {
  const PlanPage({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(ref.read(transcriptHostProvider).plan(chatId));
    final sections = plan.value;
    return Scaffold(
      appBar: PageBar(title: "Plan"),
      body: switch (sections) {
        null when plan.isLoading => const Center(
          child: CircularProgressIndicator(),
        ),
        null => const Center(child: Text("This chat has no plan.")),
        final sections => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _Progress(sections),
            PlanTaskList(sections: sections),
          ],
        ),
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.sections);

  final List<PlanSection> sections;

  @override
  Widget build(BuildContext context) {
    final (done, total) = sectionsProgress(sections);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "$done of $total tasks done",
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: total == 0 ? 0 : done / total),
        ],
      ),
    );
  }
}

/// The app bar's way to the plan, there only while the chat has one.
class PlanButton extends ConsumerWidget {
  const PlanButton({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref
        .watch(ref.read(transcriptHostProvider).plan(chatId))
        .value;
    if (sections == null) return const SizedBox.shrink();
    final (done, total) = sectionsProgress(sections);
    return IconButton(
      tooltip: "Plan, $done of $total done",
      icon: const Icon(Icons.checklist),
      onPressed: () => openPlan(context, chatId),
    );
  }
}
