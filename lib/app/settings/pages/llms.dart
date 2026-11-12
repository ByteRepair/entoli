import "../../../core/formatting.dart";
import "../../../data/builtin/llm/providers/presets.dart" show providerOf;
import "../../../domain/llm_provider.dart";
import "../../../domain/model_options.dart";
import "../../../domain/permission.dart";
import "../../../domain/settings/keys.dart";
import "../../model_role.dart";
import "../bind.dart";
import "../controller.dart";
import "../spec.dart";

const _llms = SettingsPageId.llms;
const _images = SettingsPageId.images;

const llmSections = [
  SectionSpec(page: _llms, id: "newChats", title: "New chats", weight: 0),
  SectionSpec(
    page: _llms,
    id: "agent",
    title: "Agent",
    weight: 10,
    description:
        "The built-in agent, running inside Entoli. It calls the "
        "model itself and runs its commands in the chat's workspace.",
  ),
  SectionSpec(page: _llms, id: "turns", title: "Turns", weight: 20),
  SectionSpec(
    page: _images,
    id: "imageGeneration",
    title: "Image generation",
    weight: 0,
  ),
];

final llmSettings = [
  // What a new chat gets. A live reference, not a snapshot: retargeting it
  // retargets every chat that pinned nothing.
  SettingSpec(
    id: "defaultModel",
    path: (page: _llms, section: "newChats"),
    weight: 0,
    title: "LLM",
    hint: UiHint.dropdown,
    build: (c) => c.model((
      provider: SettingKeys.defaultProviderId,
      model: SettingKeys.defaultModelId,
    ), nullLabel: "None"),
  ),
  SettingSpec(
    id: "titleModel",
    path: (page: _llms, section: "newChats"),
    weight: 10,
    title: "Title LLM",
    description:
        "Names a chat from its first message. Off, chats "
        "stay \"New chat\" until you rename them.",
    hint: UiHint.dropdown,
    build: (c) => c.model(
      (provider: SettingKeys.titleProviderId, model: SettingKeys.titleModelId),
      nullLabel: "Off",
      defaultOf: LlmProviderConfig.lightDefaultOf,
      role: ModelRole.title,
    ),
  ),
  SettingSpec(
    id: "reasoningEffort",
    path: (page: _llms, section: "newChats"),
    weight: 20,
    title: "Thinking",
    description:
        "How long a model that reasons thinks before it answers; longer is "
        "slower and costs more. Models that do not reason are sent nothing.",
    hint: UiHint.levels,
    build: (c) => c.choice(SettingKeys.reasoningEffort, [
      for (final MapEntry(key: effort, value: label)
          in reasoningEffortLabels.entries)
        SettingOption(effort, label),
    ]),
  ),
  SettingSpec(
    id: "approveMode",
    path: (page: _llms, section: "agent"),
    weight: 0,
    title: "Running commands",
    hint: UiHint.dropdown,
    build: (c) {
      final noClassifier =
          c.scope.resolve(SettingKeys.classifierProviderId) == null;
      final mode = c.scope.resolve(SettingKeys.approveMode);
      return c.choice(
        SettingKeys.approveMode,
        [
          for (final MapEntry(key: mode, value: label)
              in approveModeLabels.entries)
            SettingOption(
              mode,
              label,
              enabled: mode != ApproveMode.auto || !noClassifier,
            ),
        ],
        description: mode == ApproveMode.auto
            ? noClassifier
                  ? "No classifier model set — auto mode will ask for "
                        "every command."
                  : "The classifier can also refuse a command outright, "
                        "without asking you. Reads and writes inside the "
                        "chat's workspace pass; anything past it waits for "
                        "you. After several escalations in a turn, the rest "
                        "of the turn asks."
            : null,
      );
    },
  ),
  SettingSpec(
    id: "classifierModel",
    path: (page: _llms, section: "agent"),
    weight: 10,
    title: "Classifier LLM",
    description:
        "Classifies commands as safe, dangerous, or "
        "uncertain. Off, auto mode asks for every command.",
    hint: UiHint.dropdown,
    // The classifier travels with the mode because auto mode is unusable
    // without one.
    build: (c) => c.model(
      (
        provider: SettingKeys.classifierProviderId,
        model: SettingKeys.classifierModelId,
      ),
      nullLabel: "Off",
      defaultOf: LlmProviderConfig.lightDefaultOf,
      role: ModelRole.text,
    ),
  ),
  // How many times a failed turn is carried on before it is left failed.
  // Off is the switch; the slider is the count.
  SettingSpec(
    id: "turnRetries",
    path: (page: _llms, section: "turns"),
    weight: 0,
    title: "Retry failed turns",
    hint: UiHint.toggle,
    build: (c) {
      final retries = c.scope.resolve(SettingKeys.turnRetries)!;
      final on = retries > 0;
      return GroupController(
        c.spec,
        children: [
          ToggleController(
            c.part("on", "Automatic retry").spec,
            value: on,
            effective: on,
            onSet: (value) async {
              await c.scope.write(
                SettingKeys.turnRetries,
                (value ?? false) ? SettingKeys.defaultTurnRetries : 0,
              );
              return null;
            },
          ),
          RangeController(
            c.part("count", "Retries", hint: UiHint.slider).spec,
            value: retries,
            inherited: SettingKeys.defaultTurnRetries,
            min: 1,
            max: SettingKeys.maxTurnRetries,
            unsettable: false,
            visible: on,
            onSet: (value) async {
              await c.scope.write(SettingKeys.turnRetries, value);
              return null;
            },
          ),
        ],
        footnote: on
            ? "Carried on automatically up to ${plural(retries, "time")} "
                  "when a connection drops or "
                  "the provider fails. Off, a failed turn waits for you to "
                  "press Continue."
            : null,
      );
    },
  ),
  // Null is the backend's own default; Omada member turns run under it too,
  // and the round's own bound is the generations cap.
  SettingSpec(
    id: "turnMaxSteps",
    path: (page: _llms, section: "turns"),
    weight: 10,
    title: "Max steps per turn",
    hint: UiHint.slider,
    build: (c) => c.range(
      SettingKeys.turnMaxSteps,
      stops: SettingKeys.turnStepStops,
      unsetMeans: SettingKeys.defaultTurnMaxSteps,
    ),
  ),
  // The whole the auto-compact threshold's share is taken against: a value
  // typed occasionally, not slid to.
  SettingSpec(
    id: "totalContext",
    path: (page: _llms, section: "turns"),
    weight: 20,
    title: "Total Context",
    hint: UiHint.slider,
    build: (c) => NumberController(
      c.spec,
      value: c.scope.resolve(SettingKeys.totalContext)!,
      fallback: SettingKeys.defaultTotalContext,
      min: SettingKeys.minTotalContext,
      max: SettingKeys.maxTotalContext,
      unit: "tokens",
      prompt: "The most context a chat grows to before it compacts, in tokens",
      onSet: (value) => c.scope.write(SettingKeys.totalContext, value),
    ),
  ),
  // Summarizes the conversation when it grows past the slider's share of the
  // window. Off, a long chat grows until the provider refuses it.
  SettingSpec(
    id: "autoCompact",
    path: (page: _llms, section: "turns"),
    weight: 30,
    title: "Auto-compact",
    hint: UiHint.toggle,
    build: (c) {
      final on = c.scope.resolve(SettingKeys.autoCompact)!;
      final percent = c.scope.resolve(SettingKeys.autoCompactPercent)!;
      final total = c.scope.resolve(SettingKeys.totalContext)!;
      return GroupController(
        c.spec,
        children: [
          c
              .part("on", "Summarize long conversations")
              .toggle(SettingKeys.autoCompact),
          RangeController(
            c.part("percent", "Compact at", hint: UiHint.slider).spec,
            value: percent,
            inherited: SettingKeys.defaultAutoCompactPercent,
            stops: SettingKeys.autoCompactPercentStops,
            visible: on,
            onSet: (value) async {
              await c.scope.write(SettingKeys.autoCompactPercent, value);
              return null;
            },
          ),
        ],
        footnote: on
            ? "When a chat's context reaches $percent% of ${inK(total)} "
                  "tokens — the Total Context above — the earlier part of it "
                  "is summarized for the model; the conversation you read is "
                  "unchanged. /compact does it by hand."
            : null,
      );
    },
  ),
  // The number is always in use: off, it is what a model whose own limit is
  // not known is held to; on, it caps every model's reply. Codex builds its
  // own requests and offers no setting for their length.
  SettingSpec(
    id: "responseLength",
    path: (page: _llms, section: "turns"),
    weight: 40,
    title: "Maximum response length",
    hint: UiHint.toggle,
    build: (c) {
      final capped = c.scope.resolve(SettingKeys.capResponseLength)!;
      final length = c.scope.resolve(SettingKeys.responseLength)!;
      return GroupController(
        c.spec,
        children: [
          c
              .part("cap", "Apply a maximum response length")
              .toggle(SettingKeys.capResponseLength),
          NumberController(
            c.part("length", "Maximum response length").spec,
            value: length,
            fallback: SettingKeys.defaultResponseLength,
            min: SettingKeys.minResponseLength,
            max: SettingKeys.maxResponseLength,
            unit: "tokens",
            prompt: "Tokens, at least ${SettingKeys.minResponseLength}",
            onSet: (value) => c.scope.write(SettingKeys.responseLength, value),
          ),
        ],
        footnote: capped
            ? "Every reply is cut off at ${inK(length)} tokens, whatever "
                  "the model could write. Not applied to Codex CLI, "
                  "which sets its own."
            : "Each model writes up to its own limit. ${inK(length)} "
                  "tokens is used for a model whose limit isn't known.",
      );
    },
  ),
  // The model behind the agent's `image_generation` tool. Off, the tool is
  // not offered at all.
  SettingSpec(
    id: "imageModel",
    path: (page: _images, section: "imageGeneration"),
    weight: 0,
    title: "Image LLM",
    description:
        "Lets the agent make images, shown in the chat. "
        "Each one is a paid request to the image model. OpenAI and "
        "OpenRouter have defaults.",
    hint: UiHint.dropdown,
    build: (c) => c.model(
      (provider: SettingKeys.imageProviderId, model: SettingKeys.imageModelId),
      nullLabel: "Off",
      defaultOf: (config) => providerOf(config).imageModel,
      role: ModelRole.image,
    ),
  ),
  SettingSpec(
    id: "imageQuality",
    path: (page: _images, section: "imageGeneration"),
    weight: 10,
    title: "Quality",
    description:
        "Higher costs more and takes longer. Some providers may not "
        "accept a quality setting, and it may have no effect.",
    hint: UiHint.levels,
    build: (c) => c.choice(SettingKeys.imageQuality, [
      for (final MapEntry(key: quality, value: label)
          in imageQualityLabels.entries)
        SettingOption(quality, label),
    ], visible: c.scope.resolve(SettingKeys.imageProviderId) != null),
  ),
];
