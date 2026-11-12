import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/plan.dart";
import "../plan.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// A chat's plan: how far it has got, and every task under its heading
/// with whether it is done, each opening to the plan written for it. It
/// follows the turn, [planProvider] reading the file again as it grows.
class PlanAppPage extends AppPage {
  PlanAppPage(this.chatId);

  final String chatId;

  @override
  String get address => "plan/$chatId";

  @override
  String title(SettingReader reader) => "Plan";

  @override
  String? subtitle(SettingReader reader) {
    final sections = reader.watch(planProvider(chatId)).value;
    if (sections == null) return null;
    final (done, total) = sectionsProgress(sections);
    return "$done of $total tasks done";
  }

  @override
  List<PageSection> sections(SettingReader reader) {
    final plan = reader.watch(planProvider(chatId));
    final sections = plan.value;
    if (sections == null) {
      return [
        PageSection("none", "", [
          NoticeController(
            part("none", ""),
            lines: [
              NoticeLine(
                plan.isLoading ? "Reading the plan…" : "This chat has no plan.",
              ),
            ],
          ),
        ]),
      ];
    }
    return [
      for (final (i, section) in sections.indexed)
        PageSection("section-$i", section.heading, [
          InfoController(
            part("tasks-$i", section.heading, hint: UiHint.info),
            rows: [for (final task in section.tasks) _row(task)],
          ),
        ]),
    ];
  }

  static InfoRow _row(PlanTask task) => InfoRow(
    task.text,
    subtitle: switch (task.status) {
      PlanTaskStatus.done => "Done",
      PlanTaskStatus.inProgress => "In progress",
      PlanTaskStatus.pending => null,
    },
    glyph: switch (task.status) {
      PlanTaskStatus.done => SettingGlyph.taskDone,
      PlanTaskStatus.inProgress => SettingGlyph.taskActive,
      PlanTaskStatus.pending => SettingGlyph.taskPending,
    },
    opens: task.details.trim().isEmpty ? null : InlinePage(task.details),
  );
}
