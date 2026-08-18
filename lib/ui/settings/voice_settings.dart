import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_settings.dart";
import "../../domain/voice_model.dart";
import "../../providers.dart";
import "../voice/read_aloud.dart";
import "voice_models.dart";
import "../widgets/dialogs.dart";
import "../widgets/formatting.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// Which two models voice mode uses, over the catalog they are picked from.
/// Both pickers offer only what is downloaded, so the list below is not a menu
/// of things that might work — it is what the app has.
class VoiceSection extends ConsumerWidget {
  const VoiceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The one fact both halves of this page turn on, asked of the port rather
    // than of the store: two flags for "this is a browser" could disagree.
    final canListen = ref.watch(voiceProvider).available;
    final settings = ref.watch(appSettingsProvider);
    final installed = ref.watch(installedVoiceModelsProvider).value ?? const <String>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Voice mode",
          description: canListen
              ? "What listens and what speaks. Both run on this device: nothing "
                  "said out loud is sent anywhere the typed conversation is not."
              : "Voice mode needs a microphone and models on disk, and a "
                  "browser has neither.",
        ),
        _ModelField(
          label: "Recognition model",
          models: recognitionModels,
          installed: installed,
          selected: settings.voiceRecognitionModelId,
          onPick: (id) =>
              ref.read(appSettingsProvider.notifier).setVoiceRecognitionModel(id),
        ),
        _ModelField(
          label: "Speech model",
          models: speechModels,
          installed: installed,
          selected: settings.voiceSpeechModelId,
          onPick: (id) => ref.read(appSettingsProvider.notifier).setVoiceSpeechModel(id),
        ),
        _SpeakerField(settings: settings),
      ],
    );
  }
}

/// One kind's catalog, every entry listed whether it is installed or not, with
/// its size, what it can understand, and the button that fetches or removes it.
/// The two are separate sections because they answer separate questions: a
/// single list of eight would leave the reader working out which ones speak.
class VoiceCatalogSection extends StatelessWidget {
  const VoiceCatalogSection.recognition({super.key})
      : title = "Recognition models",
        description = "Bigger is more accurate and slower. Everything here "
            "runs on this device.",
        models = recognitionModels;

  const VoiceCatalogSection.speech({super.key})
      : title = "Speech models",
        description = "One voice each, except where the model says otherwise.",
        models = speechModels;

  final String title;
  final String description;
  final List<VoiceModel> models;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title, description: description),
          for (final model in models) VoiceModelTile(model: model),
        ],
      );
}

/// A model as a row: what it is, what it costs, and the one button that applies
/// to it — download, cancel, or delete, never more than one at a time.
class VoiceModelTile extends ConsumerWidget {
  const VoiceModelTile({super.key, required this.model});

  final VoiceModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Its own row only: a progress event names one model, and taking the whole
    // state rebuilds all eight tiles for it.
    final progress =
        ref.watch(voiceModelsProvider.select((s) => s.active[model.id]));
    final failure =
        ref.watch(voiceModelsProvider.select((s) => s.failures[model.id]));

    return ListTile(
      isThreeLine: model.note != null || progress != null || failure != null,
      title: Row(
        children: [
          Flexible(child: Text(model.name)),
          if (model.multilingual) ...[
            const SizedBox(width: 8),
            _Badge(label: "Multilingual", tone: theme.colorScheme.primary),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("${model.languages} · ${formatSize(model.bytes)}"),
          if (model.note != null)
            Text(
              model.note!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          if (failure != null)
            Text(
              failure,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress.extracting ? null : progress.fraction),
            const SizedBox(height: 4),
            Text(
              progress.extracting
                  ? "Unpacking…"
                  : "${formatSize(progress.received)} of ${formatSize(progress.total)}",
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
      trailing: _Action(model: model, downloading: progress != null),
    );
  }
}

/// Reads what it needs itself rather than being handed it: neither the
/// installed set nor whether this platform can listen appears in the row above,
/// and passing them down rebuilt the whole `ListTile` for a button.
class _Action extends ConsumerWidget {
  const _Action({required this.model, required this.downloading});

  final VoiceModel model;
  final bool downloading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = (ref.watch(installedVoiceModelsProvider).value ?? const <String>{})
        .contains(model.id);
    if (downloading) {
      return IconButton(
        icon: const Icon(Icons.close),
        tooltip: "Cancel",
        onPressed: () => ref.read(voiceModelsProvider.notifier).cancel(model.id),
      );
    }
    if (installed) {
      return IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: "Delete",
        onPressed: () => _delete(context, ref),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download_outlined),
      tooltip: "Download",
      onPressed: ref.watch(voiceProvider).available
          ? () => ref.read(voiceModelsProvider.notifier).install(model)
          : null,
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: "Delete ${model.name}?",
      message: "${formatSize(model.bytes)} to download again if you want it back.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!ok) return;
    await ref.read(voiceModelsProvider.notifier).delete(model);
  }
}

/// A dropdown over the installed models of one kind. Not the catalog: a picker
/// offering something that has to be downloaded first is a choice that fails
/// when it is used rather than when it is made.
class _ModelField extends StatelessWidget {
  const _ModelField({
    required this.label,
    required this.models,
    required this.installed,
    required this.selected,
    required this.onPick,
  });

  final String label;
  final List<VoiceModel> models;
  final Set<String> installed;
  final String? selected;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    final available = models.where((m) => installed.contains(m.id)).toList();
    if (available.isEmpty) {
      return LabelledField(
        label: label,
        child: Text(
          "Nothing downloaded yet.",
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    // A setting naming a deleted model would be a value no item carries, which
    // a DropdownButton asserts on.
    final value = available.any((m) => m.id == selected) ? selected : null;
    return LabelledField(
      label: label,
      child: DropdownButton<String?>(
        isExpanded: true,
        value: value,
        hint: const Text("None"),
        items: [
          for (final model in available)
            DropdownMenuItem(value: model.id, child: Text(model.name)),
        ],
        onChanged: onPick,
      ),
    );
  }
}

/// Which of a speech model's voices is used. Only where there is a choice: a
/// picker with one entry is a question with one answer.
class _SpeakerField extends ConsumerWidget {
  const _SpeakerField({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speech = voiceModelOf<SpeechModel>(settings.voiceSpeechModelId);
    if (speech == null) return const SizedBox.shrink();
    // Drawn even where the model has one voice, which is most of them: a field
    // that comes and goes with the model above it makes picking a model a
    // change of what the page is, and a list of one still says which voice
    // this is.
    final value = settings.voiceSpeaker.clamp(0, speech.speakers - 1);
    final playing = ref.watch(readAloudProvider) == previewId;
    return LabelledField(
      label: "Voice",
      child: Row(
        children: [
          Expanded(
            child: DropdownButton<int>(
              isExpanded: true,
              value: value,
              items: [
                for (var i = 0; i < speech.speakers; i++)
                  DropdownMenuItem(value: i, child: Text("Voice ${i + 1}")),
              ],
              onChanged: (picked) =>
                  ref.read(appSettingsProvider.notifier).setVoiceSpeaker(picked ?? 0),
            ),
          ),
          IconButton(
            // Dead until the model is on disk: the picker offers what the
            // catalog has, and a preview of something not downloaded could
            // only apologise.
            onPressed: ref.watch(speechReadyProvider) ? () => _preview(context, ref) : null,
            icon: Icon(
                playing ? Icons.stop_circle_outlined : Icons.play_circle_outline),
            tooltip: playing ? "Stop" : "Hear this voice",
          ),
        ],
      ),
    );
  }

  Future<void> _preview(BuildContext context, WidgetRef ref) async {
    final failed =
        await ref.read(readAloudProvider.notifier).toggle(previewId, previewSpeech);
    if (failed == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failed)));
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: tone),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone),
        ),
      );
}
