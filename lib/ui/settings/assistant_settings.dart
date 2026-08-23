import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/assistant_view.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// Where the system's assistant gesture lands. Two questions and nothing else:
/// which project the new chat belongs to, and which of the two views opens on
/// it. Both are the app's rather than a chat's — the gesture makes the chat.
///
/// Android's only, and drawn everywhere all the same: the settings are the
/// app's whatever it is running on, the way the voice category is drawn where
/// `Voice.available` is false.
///
/// It sits under Voice rather than in a category of its own, which is why this
/// is a file rather than a private section of the page — see the Voice
/// paragraph in CLAUDE.md.
class AssistantSection extends ConsumerWidget {
  const AssistantSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Assistant",
          description: "Android's assistant gesture opens Entoli on a new chat, "
              "once Entoli is picked as the assistant in the system's settings. "
              "Nothing else uses these.",
        ),
        LabelledField(
          label: "Project",
          child: DropdownButtonFormField<String?>(
            initialValue: projectOrDefault(settings.assistantProject, named),
            isExpanded: true,
            items: [
              for (final project in everyProject(named))
                DropdownMenuItem(value: project, child: Text(projectLabel(project))),
            ],
            onChanged: (project) =>
                ref.read(appSettingsProvider.notifier).setAssistantProject(project),
          ),
        ),
        LabelledField(
          label: "Opens",
          child: DropdownButtonFormField<AssistantView>(
            initialValue: settings.assistantView,
            isExpanded: true,
            items: [
              for (final view in AssistantView.values)
                DropdownMenuItem(value: view, child: Text(view.label)),
            ],
            onChanged: (view) {
              if (view != null) {
                ref.read(appSettingsProvider.notifier).setAssistantView(view);
              }
            },
          ),
        ),
      ],
    );
  }
}
