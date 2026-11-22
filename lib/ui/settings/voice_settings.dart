import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/scope.dart";
import "../../domain/assistant_view.dart";
import "../../domain/models.dart" show ModelChoice;
import "../../domain/project.dart";
import "../../domain/settings/keys.dart";
import "../../domain/voice_model.dart";
import "../../providers.dart";
import "../voice/read_aloud.dart";
import "../widgets/busy.dart";
import "../widgets/catalog.dart";
import "../widgets/dialogs.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "scoped.dart";

const _app = AppAddress();

/// Settings > Voice: which two models voice mode uses, picked on the same
/// catalog page as every other model, and where Android's assistant gesture
/// lands. Downloading is Settings > On-device's.
class VoiceSettings extends StatelessWidget {
  const VoiceSettings({super.key});

  @override
  Widget build(BuildContext context) =>
      ListView(children: const [_VoiceSection(), _AssistantSection()]);
}

class _VoiceSection extends ConsumerWidget {
  const _VoiceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceProvider);
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Voice mode",
          description:
              "What listens and what speaks. A model on this device "
              "keeps what is said here; a provider's is sent the recording, "
              "or the reply, to turn into the other.",
        ),
        // Where neither a download nor a provider can listen, the system's
        // engine is the only answer, and a picker of one says nothing.
        if (voice.hasModelCatalog)
          _VoicePicker(
            label: "Recognition model",
            role: ModelRole.transcription,
            off:
                "Nothing to listen with: voice mode stays off. Read-aloud "
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
        const _SpeakerField(),
        const _VoiceNameField(),
        const _LanguageField(),
        // For a room where listening the whole time does not work. It
        // replaces Mute with Talk: the same promise about the microphone,
        // made the other way round.
        const ScopedSwitch(
          setting: SettingKeys.voicePushToTalk,
          at: _app,
          title: "Touch to speak",
          subtitle:
              "Open the microphone only while the Talk button is held, "
              "instead of listening the whole time. For noisy rooms, where "
              "anything loud enough is transcribed and answered.",
        ),
        if (voice.hasEngineInstalls) const _MissingEngines(),
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
  final Future<void> Function(ModelChoice) onChanged;

  @override
  Widget build(BuildContext context) => LabelledField(
    label: label,
    child: ModelPicker(
      role: role,
      nullLabel: "None",
      defaultOf: (_) => null,
      helperOffText: off,
      choice: choice,
      onChanged: (choice) => guarded(context, () => onChanged(choice)),
    ),
  );
}

/// Reading a sample out in the picked voice, or stopping it.
class _PreviewButton extends ConsumerWidget {
  const _PreviewButton({this.enabled = true});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(readAloudProvider) == previewId;
    return IconButton(
      onPressed: enabled
          ? () => readAloud(context, ref, previewId, previewSpeech)
          : null,
      icon: Icon(
        playing ? Icons.stop_circle_outlined : Icons.play_circle_outline,
      ),
      tooltip: playing ? "Stop" : "Hear this voice",
    );
  }
}

/// The provider's name for the voice its speech model reads in. Free text:
/// models.dev lists no voices, and each provider names its own.
class _VoiceNameField extends ConsumerWidget {
  const _VoiceNameField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(pickedSpeechProvider)?.namesVoices != true) {
      return const SizedBox.shrink();
    }
    final scope = scopeOf(ref, _app);
    final name = scope.resolve(SettingKeys.voiceSpeechVoice);
    return LabelledField(
      label: "Voice",
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(name ?? "None sent"),
        subtitle: const Text(
          "The provider's own name for one, such as alloy "
          "for OpenAI. Some providers refuse a request without one.",
        ),
        onTap: () async {
          final text = await promptForText(
            context,
            title: "Voice",
            initial: name ?? "",
            hint: "As the provider names it",
            confirmLabel: "Save",
            allowBlank: true,
          );
          if (text == null || !context.mounted) return;
          final voice = text.trim();
          await guarded(
            context,
            () => scope.write(
              SettingKeys.voiceSpeechVoice,
              voice.isEmpty ? null : voice,
            ),
          );
        },
        trailing: _PreviewButton(enabled: ref.watch(speechReadyProvider)),
      ),
    );
  }
}

/// What to do when the device has no engine for one half of voice mode: an
/// empty picker is otherwise a dead end with nothing saying it is one install
/// away from working.
///
/// Recognition's half is a setting as often as an install: the framework
/// gives a recognizer the microphone only where it is the system's
/// voice-input service, so a downloaded-but-unset recognizer reads here as a
/// missing one, and is named as the same thing to do about it.
class _MissingEngines extends ConsumerWidget {
  const _MissingEngines();

  static final _rhVoice = Uri.parse(
    "https://f-droid.org/packages/com.github.olga_yakovleva.rhvoice.android/",
  );
  static final _futo = Uri.parse("https://voiceinput.futo.tech/");

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedVoiceModelsProvider);
    final hears = installed.contains(nativeRecognition.id);
    final speaks = installed.contains(nativeSpeech.id);
    if (hears && speaks) return const SizedBox.shrink();
    return Padding(
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
              "Voice input), or download a model in Settings > On-device.",
            ),
          if (!speaks)
            mutedParagraph(
              context,
              "This device has nothing to speak with. Voice mode uses the "
              "engines the platform provides, and one without the usual "
              "speech apps may have none installed. Either of these adds one, "
              "and works for every app rather than only this one:",
            ),
          const SizedBox(height: 8),
          if (!speaks)
            _EngineLink(label: "RHVoice — speech synthesis", url: _rhVoice),
          if (!hears)
            _EngineLink(
              label: "FUTO Voice Input — speech recognition",
              url: _futo,
            ),
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
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
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

/// Which of a speech model's voices is used.
class _SpeakerField extends ConsumerWidget {
  const _SpeakerField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Nothing picked, a provider's, or the system synthesiser — whose voice
    // is set in the OS, so there is no list of them here to offer.
    final speakers = ref.watch(pickedSpeechProvider)?.speakers ?? 0;
    if (speakers == 0) return const SizedBox.shrink();
    // Otherwise drawn even where the model has one voice: a field that came
    // and went with the model above would make picking one change the page.
    final scope = scopeOf(ref, _app);
    final value = scope
        .resolve(SettingKeys.voiceSpeaker)!
        .clamp(0, speakers - 1);
    return LabelledField(
      label: "Voice",
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              key: ValueKey(value),
              isExpanded: true,
              initialValue: value,
              items: [
                for (var i = 0; i < speakers; i++)
                  DropdownMenuItem(value: i, child: Text("Voice ${i + 1}")),
              ],
              onChanged: (picked) => guarded(
                context,
                () => scope.write(SettingKeys.voiceSpeaker, picked ?? 0),
              ),
            ),
          ),
          const _PreviewButton(),
        ],
      ),
    );
  }
}

/// Which language the device's own engines are asked to hear and speak in:
/// the question [_SpeakerField] answers for a downloaded model, so the two
/// never draw together. Nothing is drawn where the device names no languages.
class _LanguageField extends ConsumerWidget {
  const _LanguageField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final native =
        ref.watch(pickedRecognitionProvider)?.systemEngine == true ||
        ref.watch(pickedSpeechProvider)?.systemEngine == true;
    if (!native) return const SizedBox.shrink();
    final offered = ref.watch(systemVoiceLanguagesProvider).value ?? const [];
    if (offered.isEmpty) return const SizedBox.shrink();
    final scope = scopeOf(ref, _app);
    final picked = scope.resolve(SettingKeys.voiceLanguage);
    return InstalledPicker(
      label: "Language",
      none: "Device language",
      value: picked,
      options: {
        for (final language in offered) language.tag: language.name,
        // A settings file carried off another phone names a language this
        // one has no entry for, kept and named by its tag: the phone it came
        // from is the one that knows what it meant.
        if (picked != null && !offered.any((l) => l.tag == picked))
          picked: picked,
      },
      onPick: (tag) =>
          guarded(context, () => scope.write(SettingKeys.voiceLanguage, tag)),
    );
  }
}

/// Where the system's assistant gesture lands: which project the new chat
/// belongs to, and which view opens on it. Android's only: the settings are
/// the app's everywhere, but only a platform that can be the assistant has an
/// answer to them.
class _AssistantSection extends ConsumerWidget {
  const _AssistantSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(assistantLaunchProvider).hasGesture) {
      return const SizedBox.shrink();
    }
    final scope = scopeOf(ref, _app);
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SectionHeader(
          "Assistant",
          description:
              "Android's assistant gesture opens Entoli on a new chat, "
              "once Entoli is picked as the assistant in the system's "
              "settings. Nothing else uses these.",
        ),
        LabelledField(
          label: "Project",
          child: DropdownButtonFormField<String?>(
            initialValue: projectOrDefault(
              scope.resolve(SettingKeys.assistantProject),
              named,
            ),
            isExpanded: true,
            items: [
              for (final project in everyProject(named))
                DropdownMenuItem(
                  value: project,
                  child: Text(projectLabel(project)),
                ),
            ],
            onChanged: (project) => guarded(
              context,
              () => scope.write(SettingKeys.assistantProject, project),
            ),
          ),
        ),
        ScopedChoice(
          setting: SettingKeys.assistantView,
          at: _app,
          title: "Opens",
          options: {for (final view in AssistantView.values) view: view.label},
        ),
      ],
    );
  }
}
