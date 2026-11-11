import "../../../domain/llm_provider.dart";
import "../../../domain/settings/keys.dart";
import "../../model_role.dart";
import "../bind.dart";
import "../controller.dart";
import "../spec.dart";

const _page = SettingsPageId.memory;

// The two things the agent carries between conversations: the files the
// user writes (instructions) and the ones it writes (memories).
const memorySections = [
  SectionSpec(
    page: _page,
    id: "instructions",
    title: "Instructions",
    weight: 0,
    description:
        "The AGENTS.md files are read into every turn: yours, "
        "at the root of the data directory, and the project's, in its "
        "workspace: rules the user wrote down once. The rows below reach "
        "further than those two, or keep one of them out.",
  ),
  SectionSpec(
    page: _page,
    id: "autoMemory",
    title: "Auto memory",
    weight: 10,
    description:
        "A per-project store of short facts the agent reads into "
        "relevant turns and writes from finished ones.",
  ),
];

final memorySettings = [
  SettingSpec(
    id: "instructionImports",
    path: (page: _page, section: "instructions"),
    weight: 0,
    title: "Follow @file imports",
    description: "An @path inside an AGENTS.md pulls in the file it names.",
    hint: UiHint.toggle,
    build: (c) => c.toggle(SettingKeys.instructionImports),
  ),
  SettingSpec(
    id: "nestedInstructions",
    path: (page: _page, section: "instructions"),
    weight: 10,
    title: "Nested AGENTS.md",
    description:
        "Reading a file pulls in the AGENTS.md of every directory above it.",
    hint: UiHint.toggle,
    build: (c) => c.toggle(SettingKeys.nestedInstructions),
  ),
  SettingSpec(
    id: "instructionExcludes",
    path: (page: _page, section: "instructions"),
    weight: 20,
    title: "Excluded files",
    hint: UiHint.row,
    build: (c) => TextController(
      c.spec,
      value: (c.scope.resolve(SettingKeys.instructionExcludes) ?? []).join(
        "\n",
      ),
      emptyLabel: "None",
      prompt:
          "One glob per line. ** spans directories, * and ? do not; a "
          "pattern without a / matches a file name.",
      lines: 5,
      clearLabel: "Clear exclusions",
      onSet: (text) async {
        await c.scope.write(SettingKeys.instructionExcludes, [
          for (final line in text.split("\n"))
            if (line.trim().isNotEmpty) line.trim(),
        ]);
        return null;
      },
    ),
  ),
  SettingSpec(
    id: "autoMemory",
    path: (page: _page, section: "autoMemory"),
    weight: 0,
    title: "Keep memories",
    description: "Off, the agent keeps no memories and recalls none.",
    hint: UiHint.toggle,
    build: (c) => c.toggle(SettingKeys.autoMemory),
  ),
  for (final (i, (key, title, description)) in [
    (
      SettingKeys.memoryRecall,
      "Recall relevant memories",
      "Each turn is offered the memories its prompt is about.",
    ),
    (
      SettingKeys.memoryExtraction,
      "Write memories after a turn",
      "A background model keeps the facts a finished turn leaves "
          "behind. Needs a model below.",
    ),
    (
      SettingKeys.memoryAgentTool,
      "Memory tools",
      "The agent can save a memory it judges worth keeping, and "
          "search the store while a turn runs.",
    ),
  ].indexed)
    SettingSpec(
      id: key.key,
      path: (page: _page, section: "autoMemory"),
      weight: 10 + i,
      title: title,
      description: description,
      hint: UiHint.toggle,
      // A sub-gate of the master switch: off with it, and shown off.
      build: (c) {
        final on = c.scope.resolve(SettingKeys.autoMemory)!;
        return c.toggle(key, enabled: on, shown: on && c.scope.resolve(key)!);
      },
    ),
  SettingSpec(
    id: "memoryModel",
    path: (page: _page, section: "autoMemory"),
    weight: 20,
    title: "Memory LLM",
    description:
        "What writes memories in the background. Off, "
        "extraction is inert and the store only ever holds what the "
        "agent or you saved.",
    hint: UiHint.dropdown,
    build: (c) => c.model(
      (
        provider: SettingKeys.memoryProviderId,
        model: SettingKeys.memoryModelId,
      ),
      nullLabel: "Off",
      defaultOf: LlmProviderConfig.lightDefaultOf,
      role: ModelRole.text,
      visible: c.scope.resolve(SettingKeys.autoMemory)!,
    ),
  ),
];
