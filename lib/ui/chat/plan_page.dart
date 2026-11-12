import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/plan.dart";
import "../app_pages.dart";
import "../../app/pages/plan.dart";
import "../../domain/plan.dart";

/// Open [chatId]'s plan: the app bar's button, the plan card's and the app's
/// Chat menu.
void openPlan(BuildContext context, String chatId) =>
    openAppPage(context, PlanAppPage(chatId));

/// The app bar's way to the plan, there only while the chat has one.
class PlanButton extends ConsumerWidget {
  const PlanButton({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(planProvider(chatId)).value;
    if (sections == null) return const SizedBox.shrink();
    final (done, total) = sectionsProgress(sections);
    return IconButton(
      tooltip: "Plan, $done of $total done",
      icon: const Icon(Icons.checklist),
      onPressed: () => openPlan(context, chatId),
    );
  }
}
