import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/app_settings.dart";
import "../../domain/llm_provider.dart";
import "../../providers.dart";
import "../widgets/dialogs.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/thinking_slider.dart";

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
            defaultOf: LlmProviderConfig.lightDefaultOf,
            role: ModelRole.title,
            helperOffText:
                "Names a chat from its first message. Off, chats "
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

/// The model behind the agent's `image_generation` tool. Off, the tool is not
/// offered at all.
class ImageSection extends ConsumerWidget {
  const ImageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader("Image generation"),
        LabelledField(
          label: "Image LLM",
          child: ModelPicker(
            nullLabel: "Off",
            defaultOf: (config) => providerOf(config).imageModel,
            role: ModelRole.image,
            helperOffText:
                "Lets the agent make images, shown in the chat. "
                "Each one is a paid request to the image model. OpenAI and "
                "OpenRouter have defaults.",
            choice: (
              providerId: settings.imageProviderId,
              modelId: settings.imageModelId,
            ),
            onChanged: notifier.setImageModel,
          ),
        ),
        if (settings.imageProviderId != null)
          LabelledField(
            label: "Quality",
            child: ThinkingSlider(
              stops: imageQualityLabels,
              value: settings.imageQuality,
              onChanged: notifier.setImageQuality,
              help:
                  "Higher costs more and takes longer. Some providers may not "
                  "accept a quality setting, and it may have no effect.",
            ),
          ),
      ],
    );
  }
}

/// How long the chat LLM thinks before it answers.
class ReasoningField extends ConsumerWidget {
  const ReasoningField({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => LabelledField(
    label: "Thinking",
    child: ThinkingSlider(
      stops: reasoningEffortLabels,
      value: ref.watch(appSettingsProvider.select((s) => s.reasoningEffort)),
      onChanged: ref.read(appSettingsProvider.notifier).setReasoningEffort,
      help:
          "How long a model that reasons thinks before it answers; longer is "
          "slower and costs more. Models that do not reason are sent nothing.",
    ),
  );
}

/// How a turn runs and is bounded: the retry rounds, the step limit, the
/// context window the auto-compact threshold reads against and acts at. One
/// section because they are one subject — the turn's own behaviour — wherever
/// the page that draws it sits.
class TurnsSection extends ConsumerWidget {
  const TurnsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader("Turns"),
        const _RetryTurnsField(),
        const _MaxStepsField(),
        const _TotalContextField(),
        const _AutoCompactField(),
        const _ResponseLengthField(),
      ],
    );
  }
}

/// The most model calls one direct turn may make before it stops for the
/// user. Null is the backend's own default; Omada member turns run under it
/// too — the value rides every turn — and the round's own bound is the
/// generations cap beside it.
class _MaxStepsField extends ConsumerWidget {
  const _MaxStepsField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(appSettingsProvider.select((s) => s.turnMaxSteps));
    return InheritableSlider(
      label: "Max steps per turn",
      value: steps,
      stops: AppSettings.turnStepStops,
      inherited: AppSettings.defaultTurnMaxSteps,
      onChanged: (v) =>
          ref.read(appSettingsProvider.notifier).setTurnMaxSteps(v),
    );
  }
}

/// Auto-compact: summarize the conversation when it grows past the slider's
/// share of the model's window. Off, a long chat keeps growing until the
/// provider refuses it. The manual `/compact` needs nothing here.
class _AutoCompactField extends ConsumerWidget {
  const _AutoCompactField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(appSettingsProvider.select((s) => s.autoCompact));
    final percent = ref.watch(
      appSettingsProvider.select((s) => s.autoCompactPercent),
    );
    final total = ref.watch(appSettingsProvider.select((s) => s.totalContext));
    return LabelledField(
      label: "Auto-compact",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text("Summarize long conversations"),
            value: on,
            onChanged: (value) =>
                ref.read(appSettingsProvider.notifier).setAutoCompact(value),
          ),
          if (on) ...[
            InheritableSlider(
              label: "Compact at",
              value: percent,
              stops: AppSettings.autoCompactPercentStops,
              inherited: AppSettings.defaultAutoCompactPercent,
              onChanged: (v) => ref
                  .read(appSettingsProvider.notifier)
                  .setAutoCompactPercent(
                    v ?? AppSettings.defaultAutoCompactPercent,
                  ),
            ),
            Text(
              "When a chat's context reaches $percent% of ${total.inK} tokens "
              "— the Total Context above — the earlier part of it is "
              "summarized for the model; the conversation you read is "
              "unchanged. /compact does it by hand.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// The model's total context, in tokens — one app number, the whole the
/// auto-compact threshold's share is taken against and the summarizer's own
/// ask must fit under. Asked for in a dialog, the way a description is: a
/// value typed occasionally, not slid to.
class _TotalContextField extends ConsumerWidget {
  const _TotalContextField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(appSettingsProvider.select((s) => s.totalContext));
    return LabelledField(
      label: "Total Context",
      child: ResettableField(
        onReset: () => ref
            .read(appSettingsProvider.notifier)
            .setTotalContext(AppSettings.defaultTotalContext),
        resetLabel: "${AppSettings.defaultTotalContext.inK} (default)",
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text("${total.inK} tokens"),
          subtitle: const Text("Tap to change"),
          onTap: () async {
            final text = await promptForText(
              context,
              title: "Total Context",
              initial: "$total",
              hint: "The model's context window, in tokens",
              confirmLabel: "Save",
            );
            if (text == null || !context.mounted) return;
            final parsed = int.tryParse(text.replaceAll(",", "").trim());
            if (parsed == null) return;
            ref
                .read(appSettingsProvider.notifier)
                .setTotalContext(
                  parsed.clamp(
                    AppSettings.minTotalContext,
                    AppSettings.maxTotalContext,
                  ),
                );
          },
        ),
      ),
    );
  }
}

/// How long one reply may be. The number is always in use: off, it is what a
/// model whose own limit models.dev does not give is held to; on, it caps
/// every model's reply. Codex is the one provider it cannot reach — Codex
/// builds its own requests and offers no setting for their length.
class _ResponseLengthField extends ConsumerWidget {
  const _ResponseLengthField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capped = ref.watch(
      appSettingsProvider.select((s) => s.capResponseLength),
    );
    final length = ref.watch(
      appSettingsProvider.select((s) => s.responseLength),
    );
    return LabelledField(
      label: "Maximum response length",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text("Apply a maximum response length"),
            value: capped,
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setCapResponseLength(value),
          ),
          ResettableField(
            onReset: () => ref
                .read(appSettingsProvider.notifier)
                .setResponseLength(AppSettings.defaultResponseLength),
            resetLabel: "${AppSettings.defaultResponseLength.inK} (default)",
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text("${length.inK} tokens"),
              subtitle: const Text("Tap to change"),
              onTap: () async {
                final text = await promptForText(
                  context,
                  title: "Maximum response length",
                  initial: "$length",
                  hint: "Tokens, at least ${AppSettings.minResponseLength}",
                  confirmLabel: "Save",
                );
                if (text == null || !context.mounted) return;
                final parsed = int.tryParse(text.replaceAll(",", "").trim());
                if (parsed == null) return;
                ref
                    .read(appSettingsProvider.notifier)
                    .setResponseLength(
                      parsed.clamp(
                        AppSettings.minResponseLength,
                        AppSettings.maxResponseLength,
                      ),
                    );
              },
            ),
          ),
          Text(
            capped
                ? "Every reply is cut off at ${length.inK} tokens, whatever "
                      "the model could write. Not applied to Codex CLI, "
                      "which sets its own."
                : "Each model writes up to its own limit. ${length.inK} "
                      "tokens is used for a model whose limit isn't known.",
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// How many times a failed turn is carried on automatically before it is left
/// failed. Off is the switch; the slider is the count.
class _RetryTurnsField extends ConsumerWidget {
  const _RetryTurnsField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final retries = ref.watch(appSettingsProvider.select((s) => s.turnRetries));
    final on = retries > 0;
    return LabelledField(
      label: "Retry failed turns",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text("Automatic retry"),
            value: on,
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setTurnRetries(value ? AppSettings.defaultTurnRetries : 0),
          ),
          if (on) ...[
            Slider(
              value: retries.toDouble(),
              min: 1,
              max: AppSettings.maxTurnRetries.toDouble(),
              divisions: AppSettings.maxTurnRetries - 1,
              label: "$retries",
              onChanged: (value) => ref
                  .read(appSettingsProvider.notifier)
                  .setTurnRetries(value.round()),
            ),
            Text(
              "Carried on automatically up to $retries time${retries == 1 ? "" : "s"} "
              "when a connection drops or the provider fails. Off, a failed turn "
              "waits for you to press Continue.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

extension on int {
  String get inK =>
      this >= 1000 && this % 1000 == 0 ? "${this ~/ 1000}k" : "$this";
}
