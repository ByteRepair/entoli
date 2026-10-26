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
            helperOffText: "Lets the agent make images, shown in the chat. "
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
            child: DropdownButtonFormField<ImageQuality>(
              initialValue: settings.imageQuality,
              isExpanded: true,
              decoration: const InputDecoration(
                helperText: "Sent to OpenAI's image models; higher costs more "
                    "and takes longer. OpenRouter's image models take no "
                    "quality and ignore it.",
                helperMaxLines: 3,
              ),
              items: [
                for (final q in ImageQuality.values)
                  DropdownMenuItem(
                    value: q,
                    child: Text(switch (q) {
                      ImageQuality.auto => "Provider default",
                      ImageQuality.low => "Low",
                      ImageQuality.medium => "Medium",
                      ImageQuality.high => "High",
                    }),
                  ),
              ],
              onChanged: (value) {
                if (value != null) notifier.setImageQuality(value);
              },
            ),
          ),
      ],
    );
  }
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
    final steps = ref.watch(
        appSettingsProvider.select((s) => s.turnMaxSteps));
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
    final percent =
        ref.watch(appSettingsProvider.select((s) => s.autoCompactPercent));
    final total =
        ref.watch(appSettingsProvider.select((s) => s.totalContext));
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
                  .setAutoCompactPercent(v ?? AppSettings.defaultAutoCompactPercent),
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
                .setTotalContext(parsed.clamp(AppSettings.minTotalContext, AppSettings.maxTotalContext));
          },
        ),
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
    final retries = ref.watch(
        appSettingsProvider.select((s) => s.turnRetries));
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
  String get inK => this >= 1000 && this % 1000 == 0 ? "${this ~/ 1000}k" : "$this";
}
