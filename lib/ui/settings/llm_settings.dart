import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// What a new chat gets. A live reference, not a snapshot: retargeting it
/// retargets every chat that pinned nothing. The LLM field's Default is the
/// provider's own recommended model, resolved at turn time; the Title LLM
/// names chats and defaults to the provider's light model, with Off as an
/// explicit opt-out.
class DefaultsSection extends ConsumerWidget {
  const DefaultsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader("New chats"),
        LabelledField(
          label: "LLM",
          child: ModelPicker(
            nullLabel: noneOptionLabel,
            choice: (
              providerId: settings.defaultProviderId,
              modelId: settings.defaultModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setDefault(choice),
          ),
        ),
        LabelledField(
          label: "Title LLM",
          child: ModelPicker(
            nullLabel: "Off",
            defaultOf: (config) => config.defaultLightModelId,
            helperOffText: "Names a chat from its first message. Off, chats "
                "stay \"New chat\" until you rename them.",
            choice: (
              providerId: settings.titleProviderId,
              modelId: settings.titleModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setTitleModel(choice),
          ),
        ),
      ],
    );
  }
}