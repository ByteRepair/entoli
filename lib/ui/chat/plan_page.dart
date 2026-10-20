import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/plan.dart";
import "widgets/plan_view.dart";

/// The chat's plan on a page of its own: every task with whether it is done,
/// each opening to the plan written for it. It follows the turn, since the
/// provider re-reads the file as the conversation grows.
class PlanPage extends ConsumerWidget {
  const PlanPage({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(planProvider(chatId));
    final sections = plan.value;
    final tasks = [for (final s in sections ?? const <PlanSection>[]) ...s.tasks];
    final done = tasks.where((t) => t.status == PlanTaskStatus.done).length;
    return Scaffold(
      appBar: AppBar(title: const Text("Plan")),
      body: switch (plan) {
        AsyncValue(isLoading: true, hasValue: false) =>
          const Center(child: CircularProgressIndicator()),
        _ when sections == null =>
          const Center(child: Text("This chat has no plan.")),
        _ => ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("$done of ${tasks.length} tasks done",
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                        value: tasks.isEmpty ? 0 : done / tasks.length),
                  ],
                ),
              ),
              PlanTaskList(sections: sections),
            ],
          ),
      },
    );
  }
}
