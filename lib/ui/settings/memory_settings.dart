import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/model_role.dart";
import "../../app/settings/scope.dart";
import "../../domain/llm_provider.dart";
import "../../domain/settings/keys.dart";
import "../../domain/settings/setting.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/editable_row.dart";
import "../widgets/section_header.dart";
import "scoped.dart";

const _app = AppAddress();

/// Settings > Memory: the two things the agent carries between
/// conversations, the files the user writes (instructions) and the ones it
/// writes (memories).
class MemorySettings extends StatelessWidget {
  const MemorySettings({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    children: const [_InstructionsSection(), Divider(), _AutoMemorySection()],
  );
}

/// The sub-gates of an AGENTS.md that is read: the imports it follows, the
/// nested ones a read pulls in, and the patterns that keep a file out.
class _InstructionsSection extends ConsumerWidget {
  const _InstructionsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, _app);
    final excludes = scope.resolve(SettingKeys.instructionExcludes)!;
    Future<void> setExcludes(List<String> patterns) => guarded(
      context,
      () => scope.write(SettingKeys.instructionExcludes, patterns),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Instructions",
          description:
              "The AGENTS.md files are read into every turn: yours, "
              "at the root of the data directory, and the project's, in its "
              "workspace: rules the user wrote down once. The rows below reach "
              "further than those two, or keep one of them out.",
        ),
        const ScopedSwitch(
          setting: SettingKeys.instructionImports,
          at: _app,
          title: "Follow @file imports",
          subtitle: "An @path inside an AGENTS.md pulls in the file it names.",
        ),
        const ScopedSwitch(
          setting: SettingKeys.nestedInstructions,
          at: _app,
          title: "Nested AGENTS.md",
          subtitle:
              "Reading a file pulls in the AGENTS.md of every directory "
              "above it.",
        ),
        EditableRow(
          title: "Excluded files",
          subtitle: excludes.isEmpty ? "None" : excludes.join("\n"),
          removeLabel: "Clear exclusions",
          onTap: () async {
            final text = await promptForText(
              context,
              title: "Excluded files",
              initial: excludes.join("\n"),
              confirmLabel: "Save",
              hint:
                  "One glob per line. ** spans directories, * and ? do not; "
                  "a pattern without a / matches a file name.",
              maxLines: 5,
              allowBlank: true,
            );
            if (text == null || !context.mounted) return;
            await setExcludes([
              for (final line in text.split("\n"))
                if (line.trim().isNotEmpty) line.trim(),
            ]);
          },
          onRemove: () => setExcludes(const []),
        ),
      ],
    );
  }
}

/// The master gate, its three sub-gates and the background model that
/// writes memories.
class _AutoMemorySection extends ConsumerWidget {
  const _AutoMemorySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, _app);
    final on = scope.resolve(SettingKeys.autoMemory)!;
    // Off with the master switch, and shown off.
    Widget gate(DefaultedSetting<bool> key, String title, String subtitle) =>
        SwitchListTile(
          title: Text(title),
          subtitle: Text(subtitle),
          value: on && scope.resolve(key)!,
          onChanged: on
              ? (value) => guarded(context, () => scope.write(key, value))
              : null,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Auto memory",
          description:
              "A per-project store of short facts the agent reads into "
              "relevant turns and writes from finished ones.",
        ),
        const ScopedSwitch(
          setting: SettingKeys.autoMemory,
          at: _app,
          title: "Keep memories",
          subtitle: "Off, the agent keeps no memories and recalls none.",
        ),
        gate(
          SettingKeys.memoryRecall,
          "Recall relevant memories",
          "Each turn is offered the memories its prompt is about.",
        ),
        gate(
          SettingKeys.memoryExtraction,
          "Write memories after a turn",
          "A background model keeps the facts a finished turn leaves "
              "behind. Needs a model below.",
        ),
        gate(
          SettingKeys.memoryAgentTool,
          "Memory tools",
          "The agent can save a memory it judges worth keeping, and "
              "search the store while a turn runs.",
        ),
        if (on)
          const ScopedModel(
            keys: (
              provider: SettingKeys.memoryProviderId,
              model: SettingKeys.memoryModelId,
            ),
            at: _app,
            title: "Memory LLM",
            nullLabel: "Off",
            defaultOf: LlmProviderConfig.lightDefaultOf,
            role: ModelRole.text,
            description:
                "What writes memories in the background. Off, "
                "extraction is inert and the store only ever holds what the "
                "agent or you saved.",
          ),
      ],
    );
  }
}
