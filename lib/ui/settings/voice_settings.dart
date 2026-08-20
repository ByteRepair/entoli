import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_settings.dart";
import "../../domain/voice_model.dart";
import "../../providers.dart";
import "../voice/read_aloud.dart";
import "voice_models.dart";
import "../widgets/catalog.dart";
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
    final voice = ref.watch(voiceProvider);
    final canListen = voice.available;
    final settings = ref.watch(appSettingsProvider);
    final installed = ref.watch(installedVoiceModelsProvider);
    final hearsNatively =
        voiceModelOf<RecognitionModel>(settings.voiceRecognitionModelId)
                ?.isNative ??
            false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Voice mode",
          description: canListen
              ? _listens(hearsNatively)
              : "Voice mode needs a microphone and models on disk, and a "
                  "browser has neither.",
        ),
        // The sentinel is in the list like any other model and filtered by the
        // same `installed` set, which holds it only where the device has the
        // engine — so nothing here knows which platform it is drawing on.
        InstalledPicker(
          label: "Recognition model",
          options: _offer(const [nativeRecognition, ...recognitionModels], installed),
          value: settings.voiceRecognitionModelId,
          onPick: (id) =>
              ref.read(appSettingsProvider.notifier).setVoiceRecognitionModel(id),
        ),
        InstalledPicker(
          label: "Speech model",
          options: _offer(const [nativeSpeech, ...speechModels], installed),
          value: settings.voiceSpeechModelId,
          onPick: (id) => ref.read(appSettingsProvider.notifier).setVoiceSpeechModel(id),
        ),
        _SpeakerField(settings: settings),
        if (hearsNatively) const _OnDeviceOnlyToggle(),
        if (!voice.downloadsModels) _MissingEngines(installed: installed),
      ],
    );
  }

  /// "Nothing leaves this device" is true of every downloaded model and not of
  /// the system's recognition service, which may answer over the network — so
  /// it is not claimed where that is what is picked, and the switch below is
  /// where it becomes true again.
  static String _listens(bool natively) {
    const opening = "What listens and what speaks. ";
    if (natively) {
      return "${opening}Both are this device's own engines, and what it hears "
          "may reach the network unless the switch below keeps it here.";
    }
    return "${opening}Both run on this device: nothing said out loud is sent "
        "anywhere the typed conversation is not.";
  }
}

/// Both catalogs, or neither. Android's voice mode is the system's own engines,
/// so there is nothing to fetch and no list to draw — and the dividers belong
/// here rather than around this at the call site, or a platform with no catalog
/// would draw a line under the last thing on the page and stop.
class VoiceCatalogSections extends ConsumerWidget {
  const VoiceCatalogSections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(voiceProvider).downloadsModels) return const SizedBox.shrink();
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(),
        VoiceCatalogSection.recognition(),
        Divider(),
        VoiceCatalogSection.speech(),
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
    // Its own row only: a progress event names one model, and taking the whole
    // state rebuilds all eight tiles for it.
    final progress =
        ref.watch(voiceModelsProvider.select((s) => s.active[model.id]));
    final failure =
        ref.watch(voiceModelsProvider.select((s) => s.failures[model.id]));

    return CatalogTile(
      title: Row(
        children: [
          Flexible(child: Text(model.name)),
          if (model.multilingual) ...[
            const SizedBox(width: 8),
            _Badge(label: "Multilingual", tone: Theme.of(context).colorScheme.primary),
          ],
        ],
      ),
      summary: "${model.languages} · ${formatSize(model.bytes)}",
      note: model.note,
      failure: failure,
      progress: progress,
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
  Widget build(BuildContext context, WidgetRef ref) => CatalogAction(
        downloading: downloading,
        installed: ref.watch(installedVoiceModelsProvider).contains(model.id),
        onCancel: () => ref.read(voiceModelsProvider.notifier).cancel(model.id),
        onDelete: () => ref.read(voiceModelsProvider.notifier).delete(model),
        deleteTitle: "Delete ${model.name}?",
        deleteMessage:
            "${formatSize(model.bytes)} to download again if you want it back.",
        // A browser has nowhere to put one, so the row is drawn dead rather
        // than left out.
        onDownload: ref.watch(voiceProvider).available
            ? () => ref.read(voiceModelsProvider.notifier).install(model)
            : null,
      );
}

/// Whether the device's recognition service may use the network. Drawn only for
/// the Android sentinel, which is the one pick that has a network to use. See
/// "What is asked, and what to do when it is refused" in
/// `lib/data/voice/CLAUDE.md`.
class _OnDeviceOnlyToggle extends ConsumerWidget {
  const _OnDeviceOnlyToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(appSettingsProvider.select((s) => s.voiceOnDeviceOnly));
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text("Only listen on this device"),
      subtitle: const Text(
          "Keep what you say off the network. Android's speech recognition "
          "needs a language pack downloaded for that, in its own settings; "
          "without one, voice mode says so instead of listening online."),
      value: on,
      onChanged: ref.read(appSettingsProvider.notifier).setVoiceOnDeviceOnly,
    );
  }
}

/// What to do when the device has no engine for one half of voice mode. Only
/// drawn where there is no catalog to fall back on — on Android, where the
/// system's engines are the only ones there are, an empty picker is otherwise a
/// dead end with nothing saying it is one install away from working.
///
/// Both named engines are ordinary apps that register with the platform, so
/// installing either is the whole of the fix and nothing here has to be told
/// about it: the next launch asks the device again. Each is named for the half
/// it answers, since a phone is much more likely to be missing recognition
/// than synthesis.
class _MissingEngines extends StatelessWidget {
  const _MissingEngines({required this.installed});

  /// The usable set: a sentinel is in it only where its engine is there.
  final Set<String> installed;

  static final _rhVoice = Uri.parse(
      "https://f-droid.org/packages/com.github.olga_yakovleva.rhvoice.android/");
  static final _futo = Uri.parse("https://voiceinput.futo.tech/");

  @override
  Widget build(BuildContext context) {
    final hears = installed.contains(nativeRecognition.id);
    final speaks = installed.contains(nativeSpeech.id);
    if (hears && speaks) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final missing = [if (!hears) "hear", if (!speaks) "speak"].join(" or ");
    return Padding(
      // The inset every other block on this page keeps: `SectionHeader` above
      // and `LabelledField` between are both 16, and a paragraph flush to the
      // edge reads as belonging to something else.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "This device has nothing to $missing with. Voice mode uses the "
            "engines Android provides, and a phone without Google's apps may "
            "have none installed. Either of these adds one, and works for "
            "every app rather than only this one:",
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          if (!speaks)
            _EngineLink(label: "RHVoice — speech synthesis", url: _rhVoice),
          if (!hears)
            _EngineLink(
                label: "FUTO Voice Input — speech recognition", url: _futo),
        ],
      ),
    );
  }
}

class _EngineLink extends ConsumerWidget {
  const _EngineLink({required this.label, required this.url});

  final String label;
  final Uri url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        alignment: Alignment.centerLeft,
      ),
      onPressed: () => ref.read(linkOpenerProvider).open(context, url),
      child: Text(label),
    );
  }
}

/// The models of one kind that are actually there, as the picker takes them.
/// The sentinel is filtered by the same set as everything else, which holds it
/// only where the device has the engine — so nothing here knows which platform
/// it is on.
Map<String, String> _offer(List<VoiceModel> models, Set<String> installed) => {
      for (final model in models)
        if (installed.contains(model.id)) model.id: model.name,
    };

/// Which of a speech model's voices is used.
class _SpeakerField extends ConsumerWidget {
  const _SpeakerField({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speech = voiceModelOf<SpeechModel>(settings.voiceSpeechModelId);
    // Nothing picked, or the system synthesiser — whose voice is the user's,
    // set in the OS, so there is no list of them here to offer.
    if (speech == null || speech.isNative) return const SizedBox.shrink();
    // Otherwise drawn even where the model has one voice, which is most of
    // them: a field that came and went with the model above it would make
    // picking a model a change of what the page is.
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
            onPressed: ref.watch(speechReadyProvider)
                ? () => readAloud(context, ref, previewId, previewSpeech)
                : null,
            icon: Icon(
                playing ? Icons.stop_circle_outlined : Icons.play_circle_outline),
            tooltip: playing ? "Stop" : "Hear this voice",
          ),
        ],
      ),
    );
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
