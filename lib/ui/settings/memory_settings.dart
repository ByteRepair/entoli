import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/llm_provider.dart";
import "../../providers.dart";
import "../widgets/editable_row.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/dialogs.dart";

/// Whether the agent reads AGENTS.md at all, and the sub-gates of a file it
/// does read: the imports it follows, the nested ones a read pulls in, and
/// the patterns that keep a file out.
class InstructionsSection extends ConsumerWidget {
  const InstructionsSection({super.key});

  Future<void> _editExcludes(BuildContext context, WidgetRef ref) async {
    final text = await promptForText(
      context,
      title: "Excluded files",
      initial: ref.read(appSettingsProvider).instructionExcludes.join("\n"),
      confirmLabel: "Save",
      hint: "One glob per line. ** spans directories, * and ? do not; a "
          "pattern without a / matches a file name.",
      maxLines: 5,
    );
    if (text == null) return;
    final patterns = [
      for (final line in text.split("\n"))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    await ref
        .read(appSettingsProvider.notifier)
        .setInstructionExcludes(patterns);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final excludes = settings.instructionExcludes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Instructions",
          description: "The AGENTS.md files are read into every turn: yours, "
              "at the root of the data directory, and the project's, in its "
              "workspace: rules the user wrote down once. The rows below reach "
              "further than those two, or keep one of them out.",
        ),
        SwitchListTile(
          title: const Text("Follow @file imports"),
          subtitle: const Text(
              "An @path inside an AGENTS.md pulls in the file it names."),
          value: settings.instructionImports,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setInstructionImports(value),
        ),
        SwitchListTile(
          title: const Text("Nested AGENTS.md"),
          subtitle: const Text(
              "Reading a file pulls in a subdirectory's own AGENTS.md."),
          value: settings.nestedInstructions,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setNestedInstructions(value),
        ),
        EditableRow(
          title: "Excluded files",
          subtitle: excludes.isEmpty ? "None" : excludes.join("\n"),
          removeLabel: "Clear exclusions",
          onTap: () => _editExcludes(context, ref),
          onRemove: () => ref
              .read(appSettingsProvider.notifier)
              .setInstructionExcludes(const []),
        ),
      ],
    );
  }
}

/// Whether the auto-memory subsystem runs: the master gate, its three sub-gates
/// and the background model that writes memories.
class AutoMemorySection extends ConsumerWidget {
  const AutoMemorySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final on = settings.autoMemory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Auto memory",
          description: "A per-project store of short facts the agent reads into "
              "relevant turns and writes from finished ones.",
        ),
        SwitchListTile(
          title: const Text("Keep memories"),
          subtitle: const Text(
              "Off, the agent keeps no memories and recalls none."),
          value: on,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setAutoMemory(value),
        ),
        SwitchListTile(
          title: const Text("Recall relevant memories"),
          subtitle: const Text(
              "Each turn is offered the memories its prompt is about."),
          value: on && settings.memoryRecall,
          onChanged: on
              ? (value) => ref.read(appSettingsProvider.notifier).setMemoryRecall(value)
              : null,
        ),
        SwitchListTile(
          title: const Text("Write memories after a turn"),
          subtitle: const Text(
              "A background model keeps the facts a finished turn leaves "
              "behind. Needs a model below."),
          value: on && settings.memoryExtraction,
          onChanged: on
              ? (value) =>
                  ref.read(appSettingsProvider.notifier).setMemoryExtraction(value)
              : null,
        ),
        SwitchListTile(
          title: const Text("Memory tools"),
          subtitle: const Text(
              "The agent can save a memory it judges worth keeping, and "
              "search the store while a turn runs."),
          value: on && settings.memoryAgentTool,
          onChanged: on
              ? (value) =>
                  ref.read(appSettingsProvider.notifier).setMemoryAgentTool(value)
              : null,
        ),
        if (on)
          LabelledField(
            label: "Memory LLM",
            child: ModelPicker(
              nullLabel: "Off",
              defaultOf: LlmProviderConfig.lightDefaultOf,
              role: ModelRole.text,
              helperOffText: "What writes memories in the background. Off, "
                  "extraction is inert and the store only ever holds what the "
                  "agent or you saved.",
              choice: (
                providerId: settings.memoryProviderId,
                modelId: settings.memoryModelId,
              ),
              onChanged: (choice) =>
                  ref.read(appSettingsProvider.notifier).setMemoryModel(choice),
            ),
          ),
      ],
    );
  }
}