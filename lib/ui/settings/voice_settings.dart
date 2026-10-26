import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_settings.dart";
import "../../domain/local_model.dart" show localProviderId;
import "../../domain/models.dart" show ModelChoice;
import "../../domain/voice_model.dart";
import "../../providers.dart";
import "../voice/read_aloud.dart";
import "voice_models.dart";
import "../widgets/catalog.dart";
import "../widgets/dialogs.dart";
import "../widgets/model_picker.dart";
import "../../core/formatting.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// Which two models voice mode uses, picked on the same catalog page as every
/// other model: what is on the device under "On device", and each provider's
/// transcription and speech models beside it. Downloading is Settings >
/// On-device's.
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
    final notifier = ref.read(appSettingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Voice mode",
          description: canListen
              ? "What listens and what speaks. A model on this device keeps "
                  "what is said here; a provider's is sent the recording, or "
                  "the reply, to turn into the other."
              : "Voice mode needs a microphone, and a browser has none.",
        ),
        if (canListen) ...[
          // Where neither a download nor a provider can listen, the system's
          // engine is the only answer, and a picker of one says nothing.
          if (voice.hasModelCatalog)
            _VoicePicker(
              label: "Recognition model",
              role: ModelRole.transcription,
              off: "Nothing to listen with: voice mode stays off. Read-aloud "
                  "needs only a speech model.",
              choice: voiceRecognitionChoice(settings),
              onChanged: notifier.setVoiceRecognition,
            ),
          _VoicePicker(
            label: "Speech model",
            role: ModelRole.speech,
            off: "Nothing to speak with: replies are not read out.",
            choice: voiceSpeechChoice(settings),
            onChanged: notifier.setVoiceSpeech,
          ),
        ],
        _SpeakerField(settings: settings),
        _VoiceNameField(settings: settings),
        _LanguageField(settings: settings),
        if (canListen) const _TouchToSpeak(),
        if (voice.hasEngineInstalls) _MissingEngines(installed: installed),
      ],
    );
  }
}

/// One half's picker. No provider recommends a voice model, so no Default
/// entry.
class _VoicePicker extends StatelessWidget {
  const _VoicePicker({
    required this.label,
    required this.role,
    required this.off,
    required this.choice,
    required this.onChanged,
  });

  final String label;
  final ModelRole role;
  final String off;
  final ModelChoice choice;
  final ValueChanged<ModelChoice> onChanged;

  @override
  Widget build(BuildContext context) => LabelledField(
        label: label,
        child: ModelPicker(
          role: role,
          nullLabel: "None",
          defaultOf: (_) => null,
          helperOffText: off,
          choice: choice,
          onChanged: onChanged,
        ),
      );
}

/// The provider's name for the voice its speech model reads in. Free text:
/// models.dev lists no voices, and each provider names its own.
class _VoiceNameField extends ConsumerWidget {
  const _VoiceNameField({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (settings.voiceSpeechProviderId == localProviderId) return const SizedBox.shrink();
    final name = settings.voiceSpeechVoice;
    final playing = ref.watch(readAloudProvider) == previewId;
    return LabelledField(
      label: "Voice",
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(name ?? "None sent"),
        subtitle: const Text("The provider's own name for one, such as alloy "
            "for OpenAI. Some providers refuse a request without one."),
        onTap: () async {
          final text = await promptForText(
            context,
            title: "Voice",
            initial: name ?? "",
            hint: "As the provider names it",
            confirmLabel: "Save",
            allowBlank: true,
          );
          if (text == null) return;
          final voice = text.trim();
          await ref
              .read(appSettingsProvider.notifier)
              .setVoiceSpeechVoice(voice.isEmpty ? null : voice);
        },
        trailing: IconButton(
          onPressed: ref.watch(speechReadyProvider)
              ? () => readAloud(context, ref, previewId, previewSpeech)
              : null,
          icon: Icon(playing ? Icons.stop_circle_outlined : Icons.play_circle_outline),
          tooltip: playing ? "Stop" : "Hear this voice",
        ),
      ),
    );
  }
}

/// Whether the microphone waits to be asked. Voice mode listens for as long as
/// it is on screen, which is the point of it; this is the answer for a room
/// where that does not work — a system recogniser transcribes whatever is loud
/// enough to be speech, and somewhere noisy the only reliable way to say what
/// was meant for the phone is to say when.
///
/// It replaces Mute with Talk rather than adding a fourth button: they are the
/// same promise about the microphone, made the other way round.
class _TouchToSpeak extends ConsumerWidget {
  const _TouchToSpeak();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(appSettingsProvider.select((s) => s.voicePushToTalk));
    return SwitchListTile(
      title: const Text("Touch to speak"),
      subtitle: const Text(
          "Open the microphone only while the Talk button is held, instead of "
          "listening the whole time. For noisy rooms, where anything loud "
          "enough is transcribed and answered."),
      value: on,
      onChanged: ref.read(appSettingsProvider.notifier).setVoicePushToTalk,
    );
  }
}

/// Both voice catalogs, on the On-device page beside the text models. iOS has
/// no sherpa and no downloads, so the port's own answer takes the whole thing
/// off the page rather than leaving lists with nothing to fetch in them.
class VoiceCatalogSections extends ConsumerWidget {
  const VoiceCatalogSections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(voiceProvider).hasModelCatalog) {
      return const SizedBox.shrink();
    }
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(),
        _VoiceCatalogSection.recognition(),
        Divider(),
        _VoiceCatalogSection.speech(),
      ],
    );
  }
}

/// One kind's catalog, every entry listed whether it is installed or not, with
/// its size, what it can understand, and the button that fetches or removes it.
/// The two are separate sections because they answer separate questions: a
/// single list of eight would leave the reader working out which ones speak.
class _VoiceCatalogSection extends StatelessWidget {
  const _VoiceCatalogSection.recognition()
      : title = "Speech recognition",
        description = "What listens, for voice mode. Bigger is more accurate "
            "and slower. Everything here runs on this device.",
        models = recognitionModels;

  const _VoiceCatalogSection.speech()
      : title = "Speech synthesis",
        description = "What speaks, for voice mode and reading a reply out. "
            "One voice each, except where the model says otherwise.",
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

/// What to do when the device has no engine for one half of voice mode. Drawn
/// wherever the platform has system engines to be missing — Android, catalog
/// beside it — because an empty picker is otherwise a dead end with nothing
/// saying it is one install away from working.
///
/// Recognition's half is about a *setting* as often as about an install: the
/// framework gives a recognizer the microphone only where it is the one set as
/// the system's voice-input service, so a downloaded-but-unset recognizer is
/// indistinguishable from a missing one from here — and named as the same
/// thing to do about it. Both named engines are ordinary apps that register
/// with the platform, so installing either is the whole of the fix and
/// nothing here has to be told about it: the next launch asks the device
/// again. Each is named for the half it answers, since a phone is much more
/// likely to be missing recognition than synthesis.
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
    return Padding(
      // The inset every other block on this page keeps: `SectionHeader` above
      // and `LabelledField` between are both 16, and a paragraph flush to the
      // edge reads as belonging to something else.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hears)
            mutedParagraph(
                context,
                "This device has nothing to hear with. Android gives a "
                "recognizer the microphone only where it is the one set as the "
                "system's voice-input service — set one there "
                "(Settings → Apps → Default apps → Digital assistant app → "
                "Voice input), or download a model in Settings > On-device."),
          if (!speaks)
            mutedParagraph(
                context,
                "This device has nothing to speak with. Voice mode uses the "
                "engines the platform provides, and one without the usual "
                "speech apps may have none installed. Either of these adds one, "
                "and works for every app rather than only this one:"),
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

/// Which of a speech model's voices is used.
class _SpeakerField extends ConsumerWidget {
  const _SpeakerField({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speech = settings.voiceSpeechProviderId == localProviderId
        ? voiceModelOf<SpeechModel>(settings.voiceSpeechModelId)
        : null;
    // Nothing picked, a provider's, or the system synthesiser — whose voice is the user's,
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
            child: DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: value,
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

/// Which language the device's own engines are asked to hear and speak in —
/// the question [_SpeakerField] answers for a downloaded model, which is why
/// the two are siblings that never draw together.
///
/// Nothing is drawn where the device names no languages: a browser, a desktop,
/// and a phone whose synthesiser would not answer. A picker holding only the
/// device's own language is a control that cannot say anything.
class _LanguageField extends ConsumerWidget {
  const _LanguageField({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final native = settings.voiceRecognitionProviderId == localProviderId &&
            voiceModelOf<RecognitionModel>(settings.voiceRecognitionModelId)?.isNative ==
                true ||
        settings.voiceSpeechProviderId == localProviderId &&
            voiceModelOf<SpeechModel>(settings.voiceSpeechModelId)?.isNative == true;
    if (!native) return const SizedBox.shrink();
    final offered = ref.watch(systemVoiceLanguagesProvider).value ?? const [];
    if (offered.isEmpty) return const SizedBox.shrink();
    final picked = settings.voiceLanguage;
    return InstalledPicker(
      label: "Language",
      none: "Device language",
      value: picked,
      options: {
        for (final language in offered) language.tag: language.name,
        // A settings file carried off another phone names a language this one
        // has no entry for. Kept and named by its tag rather than reset to the
        // device's: the phone it came from is the one that knows what it meant.
        if (picked != null && !offered.any((l) => l.tag == picked)) picked: picked,
      },
      onPick: ref.read(appSettingsProvider.notifier).setVoiceLanguage,
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
