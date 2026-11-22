import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/model_role.dart";
import "../../app/settings/scope.dart";
import "../../core/formatting.dart" show inK, plural;
import "../../data/builtin/llm/providers/presets.dart" show providerOf;
import "../../domain/llm_provider.dart";
import "../../domain/model_options.dart";
import "../../domain/permission.dart";
import "../../domain/settings/keys.dart";
import "../../domain/settings/setting.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "scoped.dart";

const _app = AppAddress();

/// What answers a new chat. A live reference, not a snapshot: retargeting it
/// retargets every chat that pinned nothing.
const newChatModelField = ScopedModel(
  keys: (
    provider: SettingKeys.defaultProviderId,
    model: SettingKeys.defaultModelId,
  ),
  at: _app,
  title: "LLM",
  nullLabel: noneOptionLabel,
);

/// What names a new chat.
const titleModelField = ScopedModel(
  keys: (
    provider: SettingKeys.titleProviderId,
    model: SettingKeys.titleModelId,
  ),
  at: _app,
  title: "Title LLM",
  nullLabel: "Off",
  defaultOf: LlmProviderConfig.lightDefaultOf,
  role: ModelRole.shortAsk,
  description:
      "Names a chat from its first message. Off, chats "
      "stay \"New chat\" until you rename them.",
);

/// Settings > LLMs: what a new chat is answered by and what names it, how
/// long it thinks, the agent's command gate, and how a turn is bounded.
class LlmSettings extends StatelessWidget {
  const LlmSettings({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    children: const [
      SectionHeader("New chats"),
      newChatModelField,
      titleModelField,
      ScopedLevels(
        setting: SettingKeys.reasoningEffort,
        at: _app,
        title: "Thinking",
        stops: reasoningEffortLabels,
        help:
            "How long a model that reasons thinks before it answers; longer "
            "is slower and costs more. Models that do not reason are sent "
            "nothing.",
      ),
      Divider(),
      _AgentSection(),
      Divider(),
      _TurnsSection(),
    ],
  );
}

/// Settings > Image Generation: the model behind the agent's
/// `image_generation` tool. Off, the tool is not offered at all.
class ImageSettings extends ConsumerWidget {
  const ImageSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picked =
        scopeOf(ref, _app).resolve(SettingKeys.imageProviderId) != null;
    return ListView(
      children: [
        const SectionHeader("Image generation"),
        ScopedModel(
          keys: (
            provider: SettingKeys.imageProviderId,
            model: SettingKeys.imageModelId,
          ),
          at: _app,
          title: "Image LLM",
          nullLabel: "Off",
          defaultOf: (config) => providerOf(config).imageModel,
          role: ModelRole.image,
          description:
              "Lets the agent make images, shown in the chat. "
              "Each one is a paid request to the image model. OpenAI and "
              "OpenRouter have defaults.",
        ),
        if (picked)
          const ScopedLevels(
            setting: SettingKeys.imageQuality,
            at: _app,
            title: "Quality",
            stops: imageQualityLabels,
            help:
                "Higher costs more and takes longer. Some providers may not "
                "accept a quality setting, and it may have no effect.",
          ),
      ],
    );
  }
}

/// The built-in agent's command gate. The classifier travels with the mode
/// because auto mode is unusable without one.
class _AgentSection extends StatelessWidget {
  const _AgentSection();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader(
        "Agent",
        description:
            "The built-in agent, running inside Entoli. It calls the "
            "model itself and runs its commands in the chat's workspace.",
      ),
      ApproveModeChoice(at: _app),
      ScopedModel(
        keys: (
          provider: SettingKeys.classifierProviderId,
          model: SettingKeys.classifierModelId,
        ),
        at: _app,
        title: "Classifier LLM",
        nullLabel: "Off",
        defaultOf: LlmProviderConfig.lightDefaultOf,
        role: ModelRole.shortAsk,
        description:
            "Classifies commands as safe, dangerous, or "
            "uncertain. Off, auto mode asks for every command.",
      ),
    ],
  );
}

/// Whether a command waits for the user, at [at]: the app's answer, or a
/// chat's own.
class ApproveModeChoice extends ConsumerWidget {
  const ApproveModeChoice({super.key, required this.at});

  final ScopeAddress at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    final noClassifier =
        scope.resolve(SettingKeys.classifierProviderId) == null;
    final auto = scope.resolve(SettingKeys.approveMode) == ApproveMode.auto;
    return ScopedChoice(
      setting: SettingKeys.approveMode,
      at: at,
      title: "Running commands",
      options: approveModeLabels,
      disabled: {if (noClassifier) ApproveMode.auto},
      description: !auto
          ? null
          : noClassifier
          ? "No classifier model set — auto mode will ask for every command."
          : "The classifier can also refuse a command outright, without "
                "asking you. Reads and writes inside the chat's workspace "
                "pass; anything past it waits for you. After several "
                "escalations in a turn, the rest of the turn asks.",
    );
  }
}

/// How a turn runs and is bounded: the retry rounds, the step limit, the
/// context window the auto-compact threshold reads against and acts at, and
/// how long a reply may be.
class _TurnsSection extends ConsumerWidget {
  const _TurnsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, _app);
    final small = Theme.of(context).textTheme.bodySmall;
    void write<T extends Object>(Setting<T> setting, T? value) =>
        guarded(context, () => scope.write(setting, value));

    final retries = scope.resolve(SettingKeys.turnRetries)!;
    final retrying = retries > 0;
    final compacting = scope.resolve(SettingKeys.autoCompact)!;
    final percent = scope.resolve(SettingKeys.autoCompactPercent)!;
    final total = scope.resolve(SettingKeys.totalContext)!;
    final capped = scope.resolve(SettingKeys.capResponseLength)!;
    final length = scope.resolve(SettingKeys.responseLength)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader("Turns"),
        // Off is the switch; the slider is the count.
        LabelledField(
          label: "Retry failed turns",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text("Automatic retry"),
                value: retrying,
                onChanged: (on) => write(
                  SettingKeys.turnRetries,
                  on ? SettingKeys.defaultTurnRetries : 0,
                ),
              ),
              if (retrying) ...[
                Slider(
                  value: retries.toDouble(),
                  min: 1,
                  max: SettingKeys.maxTurnRetries.toDouble(),
                  divisions: SettingKeys.maxTurnRetries - 1,
                  label: "$retries",
                  onChanged: (value) =>
                      write(SettingKeys.turnRetries, value.round()),
                ),
                Text(
                  "Carried on automatically up to ${plural(retries, "time")} "
                  "when a connection drops or the provider fails. Off, a "
                  "failed turn waits for you to press Continue.",
                  style: small,
                ),
              ],
            ],
          ),
        ),
        // Null is the backend's own default; Omada member turns run under it
        // too, and the round's own bound is the generations cap.
        const ScopedCount(
          setting: SettingKeys.turnMaxSteps,
          at: _app,
          title: "Max steps per turn",
          stops: SettingKeys.turnStepStops,
          unsetMeans: SettingKeys.defaultTurnMaxSteps,
        ),
        LabelledField(
          label: "Total Context",
          child: _TokenCountTile(
            title: "Total Context",
            hint:
                "The most context a chat grows to before it compacts, in "
                "tokens",
            value: total,
            defaultValue: SettingKeys.defaultTotalContext,
            min: SettingKeys.minTotalContext,
            max: SettingKeys.maxTotalContext,
            onSet: (v) => scope.write(SettingKeys.totalContext, v),
          ),
        ),
        // Off, a long chat grows until the provider refuses it.
        LabelledField(
          label: "Auto-compact",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text("Summarize long conversations"),
                value: compacting,
                onChanged: (on) => write(SettingKeys.autoCompact, on),
              ),
              if (compacting) ...[
                const ScopedCount(
                  setting: SettingKeys.autoCompactPercent,
                  at: _app,
                  title: "Compact at",
                  stops: SettingKeys.autoCompactPercentStops,
                  unsetMeans: SettingKeys.defaultAutoCompactPercent,
                ),
                Text(
                  "When a chat's context reaches $percent% of ${inK(total)} "
                  "tokens — the Total Context above — the earlier part of it "
                  "is summarized for the model; the conversation you read is "
                  "unchanged. /compact does it by hand.",
                  style: small,
                ),
              ],
            ],
          ),
        ),
        // The number is always in use: off, it is what a model whose own
        // limit is not known is held to; on, it caps every model's reply.
        // Codex builds its own requests and offers no setting for their
        // length.
        LabelledField(
          label: "Maximum response length",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text("Apply a maximum response length"),
                value: capped,
                onChanged: (on) => write(SettingKeys.capResponseLength, on),
              ),
              _TokenCountTile(
                title: "Maximum response length",
                hint: "Tokens, at least ${SettingKeys.minResponseLength}",
                value: length,
                defaultValue: SettingKeys.defaultResponseLength,
                min: SettingKeys.minResponseLength,
                max: SettingKeys.maxResponseLength,
                onSet: (v) => scope.write(SettingKeys.responseLength, v),
              ),
              Text(
                capped
                    ? "Every reply is cut off at ${inK(length)} tokens, "
                          "whatever the model could write. Not applied to "
                          "Codex CLI, which sets its own."
                    : "Each model writes up to its own limit. ${inK(length)} "
                          "tokens is used for a model whose limit isn't "
                          "known.",
                style: small,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A count of tokens, typed in a dialog rather than slid to — a value set
/// occasionally — kept within [min] and [max], with a reset to its default.
class _TokenCountTile extends StatelessWidget {
  const _TokenCountTile({
    required this.title,
    required this.hint,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.onSet,
  });

  final String title;
  final String hint;
  final int value;
  final int defaultValue;
  final int min;
  final int max;
  final Future<void> Function(int) onSet;

  @override
  Widget build(BuildContext context) => ResettableField(
    onReset: () => guarded(context, () => onSet(defaultValue)),
    resetLabel: "${inK(defaultValue)} (default)",
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text("${inK(value)} tokens"),
      subtitle: const Text("Tap to change"),
      onTap: () async {
        final text = await promptForText(
          context,
          title: title,
          initial: "$value",
          hint: hint,
          confirmLabel: "Save",
        );
        if (text == null || !context.mounted) return;
        final parsed = int.tryParse(text.replaceAll(",", "").trim());
        if (parsed == null) return say(context, "\"$text\" is not a number.");
        await guarded(context, () => onSet(parsed.clamp(min, max)));
      },
    ),
  );
}
