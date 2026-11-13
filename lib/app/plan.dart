import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/plan.dart";
import "../providers.dart";
import "mirror_controller.dart" show chatViewProvider;

/// The chat's `PLAN.md`, parsed; null where there is none or it could not be
/// read. A mirrored chat's is asked of its home device over the sync channel.
/// Read again when [planRevision] moves rather than watched, since every
/// write to the file lands in the conversation as a result.
final planProvider = FutureProvider.autoDispose
    .family<List<PlanSection>?, String>((ref, chatId) async {
      ref.watch(
        chatViewProvider(
          chatId,
        ).select((view) => planRevision(view.chat?.messages ?? const [])),
      );
      final text = ref.watch(isMirroredChatProvider(chatId))
          ? await ref.read(syncHubProvider).planText(chatId)
          : await ref.read(chatRepositoryProvider).readPlan(chatId);
      final sections = planSectionsFrom(text);
      return sections.isEmpty ? null : sections;
    });

/// The line under a plan's title.
String planProgressLine(List<PlanSection>? sections, {required bool loading}) {
  if (sections != null) {
    final (done, total) = sectionsProgress(sections);
    return "$done of $total tasks done";
  }
  // A mirror's first read is a round trip to the home device.
  return loading ? "Reading the plan…" : "The plan could not be read.";
}
