import "../../../domain/assistant_view.dart";
import "../../../domain/app_settings.dart";
import "../../../domain/project.dart";
import "../../../domain/settings/keys.dart";
import "../../../domain/voice_model.dart";
import "../../../providers.dart";
import "../../model_role.dart";
import "../../read_aloud.dart";
import "../bind.dart";
import "../controller.dart";
import "../spec.dart";

const _page = SettingsPageId.voice;

final voiceSections = [
  const SectionSpec(
    page: _page,
    id: "voiceMode",
    title: "Voice mode",
    weight: 0,
    description:
        "What listens and what speaks. A model on this device "
        "keeps what is said here; a provider's is sent the recording, "
        "or the reply, to turn into the other.",
  ),
  // Where the system's assistant gesture lands: which project the new chat
  // belongs to, and which view opens on it. Android's only: the settings are
  // the app's everywhere, but only a platform that can be the assistant has
  // an answer to them.
  SectionSpec(
    page: _page,
    id: "assistant",
    title: "Assistant",
    weight: 10,
    description:
        "Android's assistant gesture opens Entoli on a new chat, "
        "once Entoli is picked as the assistant in the system's settings. "
        "Nothing else uses these.",
    shown: (ref) => ref.watch(assistantLaunchProvider).hasGesture,
  ),
];

/// Reading [previewSpeech] out, or stopping it, beside a voice field.
ActionController _preview(SettingContext c, {bool enabled = true}) {
  final playing = c.ref.watch(readAloudProvider) == previewId;
  final reader = c.ref.read(readAloudProvider.notifier);
  return ActionController(
    SettingSpec(
      id: "${c.spec.id}.preview",
      path: c.spec.path,
      weight: 0,
      title: playing ? "Stop" : "Hear this voice",
      hint: UiHint.button,
      glyph: SettingGlyph.play,
      build: c.spec.build,
    ),
    label: playing ? "Stop" : "Hear this voice",
    glyphOverride: playing ? SettingGlyph.stop : SettingGlyph.play,
    enabled: enabled,
    run: () async {
      final failed = await reader.toggle(previewId, previewSpeech);
      return failed == null ? null : SettingNotice(failed);
    },
  );
}

final voiceSettings = [
  // Where neither a download nor a provider can listen, the system's engine
  // is the only answer, and a picker of one says nothing. No provider
  // recommends a voice model, so no Default entry.
  SettingSpec(
    id: "voiceRecognition",
    path: (page: _page, section: "voiceMode"),
    weight: 0,
    title: "Recognition model",
    description:
        "Nothing to listen with: voice mode stays off. Read-aloud "
        "needs only a speech model.",
    hint: UiHint.dropdown,
    build: (c) => c.model(
      (
        provider: SettingKeys.voiceRecognitionProviderId,
        model: SettingKeys.voiceRecognitionModelId,
      ),
      nullLabel: "None",
      defaultOf: (_) => null,
      role: ModelRole.transcription,
      visible: c.ref.watch(voiceProvider).hasModelCatalog,
      write: c.ref.read(appSettingsProvider.notifier).setVoiceRecognition,
      choice: voiceRecognitionChoice(AppSettings.of(c.scope.root.document)),
    ),
  ),
  SettingSpec(
    id: "voiceSpeech",
    path: (page: _page, section: "voiceMode"),
    weight: 10,
    title: "Speech model",
    description: "Nothing to speak with: replies are not read out.",
    hint: UiHint.dropdown,
    // Picking a different voice resets which of its speakers is used.
    build: (c) => c.model(
      (
        provider: SettingKeys.voiceSpeechProviderId,
        model: SettingKeys.voiceSpeechModelId,
      ),
      nullLabel: "None",
      defaultOf: (_) => null,
      role: ModelRole.speech,
      write: c.ref.read(appSettingsProvider.notifier).setVoiceSpeech,
      choice: voiceSpeechChoice(AppSettings.of(c.scope.root.document)),
    ),
  ),
  // Which of a speech model's voices is used. Not drawn for nothing picked,
  // a provider's, or the system synthesiser — whose voice is set in the OS.
  // Otherwise drawn even where the model has one voice: a field that came and
  // went with the model above would make picking one change the page.
  SettingSpec(
    id: "voiceSpeaker",
    path: (page: _page, section: "voiceMode"),
    weight: 20,
    title: "Voice",
    hint: UiHint.dropdown,
    build: (c) {
      final speakers = c.ref.watch(pickedSpeechProvider)?.speakers ?? 0;
      final value = speakers == 0
          ? 0
          : c.scope.resolve(SettingKeys.voiceSpeaker)!.clamp(0, speakers - 1);
      return ChoiceController<int>(
        c.spec,
        options: [
          for (var i = 0; i < speakers; i++) SettingOption(i, "Voice ${i + 1}"),
        ],
        value: value,
        visible: speakers > 0,
        accessory: _preview(c),
        onSet: (picked) async {
          await c.scope.write(SettingKeys.voiceSpeaker, picked ?? 0);
          return null;
        },
      );
    },
  ),
  // The provider's name for the voice its speech model reads in. Free text:
  // models.dev lists no voices, and each provider names its own.
  SettingSpec(
    id: "voiceSpeechVoice",
    path: (page: _page, section: "voiceMode"),
    weight: 30,
    title: "Voice",
    description:
        "The provider's own name for one, such as alloy "
        "for OpenAI. Some providers refuse a request without one.",
    hint: UiHint.field,
    build: (c) => TextController(
      c.spec,
      value: c.scope.resolve(SettingKeys.voiceSpeechVoice) ?? "",
      emptyLabel: "None sent",
      prompt: "As the provider names it",
      allowBlank: true,
      visible: c.ref.watch(pickedSpeechProvider)?.namesVoices == true,
      accessory: _preview(c, enabled: c.ref.watch(speechReadyProvider)),
      onSet: (text) async {
        final voice = text.trim();
        await c.scope.write(
          SettingKeys.voiceSpeechVoice,
          voice.isEmpty ? null : voice,
        );
        return null;
      },
    ),
  ),
  // Which language the device's own engines are asked in: the question the
  // speaker answers for a downloaded model, so the two never draw together.
  // Nothing is drawn where the device names no languages.
  SettingSpec(
    id: "voiceLanguage",
    path: (page: _page, section: "voiceMode"),
    weight: 40,
    title: "Language",
    hint: UiHint.dropdown,
    build: (c) {
      final native =
          c.ref.watch(pickedRecognitionProvider)?.systemEngine == true ||
          c.ref.watch(pickedSpeechProvider)?.systemEngine == true;
      final offered = native
          ? c.ref.watch(systemVoiceLanguagesProvider).value ?? const []
          : const [];
      final picked = c.scope.resolve(SettingKeys.voiceLanguage);
      return ChoiceController<String>(
        c.spec,
        options: [
          for (final language in offered)
            SettingOption(language.tag, language.name),
          // A settings file carried off another phone names a language this
          // one has no entry for, kept and named by its tag: the phone it came
          // from is the one that knows what it meant.
          if (picked != null && !offered.any((l) => l.tag == picked))
            SettingOption(picked, picked),
        ],
        value: picked,
        noneLabel: "Device language",
        visible: offered.isNotEmpty,
        onSet: (tag) async {
          await c.scope.write(SettingKeys.voiceLanguage, tag);
          return null;
        },
      );
    },
  ),
  // Whether the microphone waits to be asked: for a room where listening the
  // whole time does not work. It replaces Mute with Talk: the same promise
  // about the microphone, made the other way round.
  SettingSpec(
    id: "voicePushToTalk",
    path: (page: _page, section: "voiceMode"),
    weight: 50,
    title: "Touch to speak",
    description:
        "Open the microphone only while the Talk button is held, instead of "
        "listening the whole time. For noisy rooms, where anything loud "
        "enough is transcribed and answered.",
    hint: UiHint.toggle,
    build: (c) => c.toggle(SettingKeys.voicePushToTalk),
  ),
  // What to do when the device has no engine for one half of voice mode:
  // an empty picker is otherwise a dead end with nothing saying it is one
  // install away from working. Recognition's half is a setting as often as an
  // install: the framework gives a recognizer the microphone only where it is
  // the system's voice-input service.
  SettingSpec(
    id: "missingEngines",
    path: (page: _page, section: "voiceMode"),
    weight: 60,
    title: "Missing engines",
    hint: UiHint.notice,
    build: (c) {
      final installed = c.ref.watch(installedVoiceModelsProvider);
      final hears = installed.contains(nativeRecognition.id);
      final speaks = installed.contains(nativeSpeech.id);
      return NoticeController(
        c.spec,
        visible:
            c.ref.watch(voiceProvider).hasEngineInstalls && !(hears && speaks),
        lines: [
          if (!hears)
            const NoticeLine(
              "This device has nothing to hear with. Android gives a "
              "recognizer the microphone only where it is the one set as the "
              "system's voice-input service — set one there "
              "(Settings → Apps → Default apps → Digital assistant app → "
              "Voice input), or download a model in Settings > On-device.",
            ),
          if (!speaks)
            const NoticeLine(
              "This device has nothing to speak with. Voice mode uses the "
              "engines the platform provides, and one without the usual "
              "speech apps may have none installed. Either of these adds one, "
              "and works for every app rather than only this one:",
            ),
          if (!speaks)
            NoticeLine(
              "RHVoice — speech synthesis",
              url: Uri.parse(
                "https://f-droid.org/packages/"
                "com.github.olga_yakovleva.rhvoice.android/",
              ),
            ),
          if (!hears)
            NoticeLine(
              "FUTO Voice Input — speech recognition",
              url: Uri.parse("https://voiceinput.futo.tech/"),
            ),
        ],
      );
    },
  ),
  SettingSpec(
    id: "assistantProject",
    path: (page: _page, section: "assistant"),
    weight: 0,
    title: "Project",
    hint: UiHint.dropdown,
    build: (c) {
      final named = c.ref.watch(projectListProvider).value ?? const <String>[];
      return ChoiceController<String?>(
        c.spec,
        options: [
          for (final project in everyProject(named))
            SettingOption(project, projectLabel(project)),
        ],
        value: projectOrDefault(
          c.scope.resolve(SettingKeys.assistantProject),
          named,
        ),
        onSet: (project) async {
          await c.scope.write(SettingKeys.assistantProject, project);
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "assistantView",
    path: (page: _page, section: "assistant"),
    weight: 10,
    title: "Opens",
    hint: UiHint.dropdown,
    build: (c) => c.choice(SettingKeys.assistantView, [
      for (final view in AssistantView.values) SettingOption(view, view.label),
    ]),
  ),
];
