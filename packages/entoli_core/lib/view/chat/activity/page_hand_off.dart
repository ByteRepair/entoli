import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../transcript/handoff.dart";
import "../../../transcript/activity.dart";
import "../../widgets/notice.dart";
import "../plan_page.dart" as plan_page;
import "card.dart" show showActivityDetail;

/// A hand-off that pushes pages over the [context] of what was tapped. A
/// detail, the plan and an artifact open the same wherever the transcript is
/// drawn; what differs between the app and the viewer is the rest.
abstract class PageHandOff implements TranscriptHandOff {
  const PageHandOff(this.context);

  final BuildContext context;

  ProviderContainer get container =>
      ProviderScope.containerOf(context, listen: false);

  @override
  Future<void> openDetail(OpensDetail detail) =>
      showActivityDetail(context, detail);

  @override
  Future<void> openPlan(String chatId) async =>
      plan_page.openPlan(context, chatId);

  @override
  Future<void> openArtifact(
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) => attempt(
    () => container
        .read(linkOpenerProvider)
        .openArtifact(
          context,
          chatId,
          artifactId,
          entryFile: entryFile,
          title: title,
        ),
  );

  @override
  Future<void> attempt(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (context.mounted) say(context, error);
    }
  }
}
