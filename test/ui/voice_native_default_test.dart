import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/voice.dart";
import "package:agent_chat/domain/voice_model.dart";
import "package:agent_chat/providers.dart";

import "../harness.dart";

const bothEngines = NativeVoiceEngines(recognition: true, speech: true);

void main() {
  group("the Android native default", () {
    test("voice mode is ready with nothing downloaded", () async {
      final app = TestApp.create(nativeVoice: bothEngines);
      addTearDown(app.dispose);
      expect(app.container.read(voiceReadyProvider), isTrue);
      expect(app.container.read(speechReadyProvider), isTrue);
    });

    test("the picks default to the Android-system sentinels", () async {
      final app = TestApp.create(nativeVoice: bothEngines);
      addTearDown(app.dispose);
      final settings = app.container.read(appSettingsProvider);
      expect(settings.voiceRecognitionModelId, nativeRecognition.id);
      expect(settings.voiceSpeechModelId, nativeSpeech.id);
    });

    test("a settings file naming a sherpa model is left as it is", () async {
      final app = TestApp.create(nativeVoice: bothEngines);
      addTearDown(app.dispose);
      await app.seedSettings(
        AppSettings(voiceSpeechModelId: "piper-en_US-amy"));
      // Reloading the notifier re-runs `build`, which is where the default is
      // filled. The recognition half stays null (the settings file did not
      // name one), the speech half stays as seeded.
      app.container.invalidate(appSettingsProvider);
      final settings = app.container.read(appSettingsProvider);
      expect(settings.voiceSpeechModelId, "piper-en_US-amy");
      expect(settings.voiceRecognitionModelId, nativeRecognition.id);
    });

    test("the default is not written to disk", () async {
      final app = TestApp.create(nativeVoice: bothEngines);
      addTearDown(app.dispose);
      // Read the settings so the default is materialised, then check the file
      // is empty — the defaulting is in-memory only.
      app.container.read(appSettingsProvider);
      expect(app.config.documents.read(app.config.settingsFile), isNull);
    });
  });

  group("a device missing an engine", () {
    test("nothing is picked for the half it cannot do", () async {
      final app = TestApp.create(
        nativeVoice: const NativeVoiceEngines(recognition: false, speech: true),
      );
      addTearDown(app.dispose);
      final settings = app.container.read(appSettingsProvider);
      expect(settings.voiceSpeechModelId, nativeSpeech.id);
      // No recognition service installed — a phone with no Google apps on it.
      // Defaulting it to the sentinel would be a pick that fails when pressed.
      expect(settings.voiceRecognitionModelId, isNull);
    });

    test("half an engine reads a message out but does not open voice mode",
        () async {
      final app = TestApp.create(
        nativeVoice: const NativeVoiceEngines(recognition: false, speech: true),
      );
      addTearDown(app.dispose);
      expect(app.container.read(speechReadyProvider), isTrue);
      expect(app.container.read(voiceReadyProvider), isFalse);
    });

    test("with neither, nothing is picked and nothing is offered", () async {
      final app = TestApp.create(nativeVoice: NativeVoiceEngines.none);
      addTearDown(app.dispose);
      final settings = app.container.read(appSettingsProvider);
      expect(settings.voiceRecognitionModelId, isNull);
      expect(settings.voiceSpeechModelId, isNull);
      expect(app.container.read(speechReadyProvider), isFalse);
    });

    test("a sentinel already in the settings file is not honoured either",
        () async {
      final app = TestApp.create(
        nativeVoice: const NativeVoiceEngines(recognition: true, speech: false),
      );
      addTearDown(app.dispose);
      await app.seedSettings(AppSettings(voiceSpeechModelId: nativeSpeech.id));
      app.container.invalidate(appSettingsProvider);
      // Pinned by hand, or carried from a phone that had a synthesiser. Either
      // way there is nothing here to say it with.
      expect(app.container.read(speechReadyProvider), isFalse);
    });
  });

  group("off Android", () {
    test("voice mode is not ready with nothing downloaded", () async {
      final app = TestApp.create();
      addTearDown(app.dispose);
      expect(app.container.read(voiceReadyProvider), isFalse);
      expect(app.container.read(speechReadyProvider), isFalse);
    });

    test("a settings file carried from a phone does not light up read-aloud",
        () async {
      final app = TestApp.create();
      addTearDown(app.dispose);
      await app.seedSettings(
        AppSettings(voiceSpeechModelId: nativeSpeech.id));
      app.container.invalidate(appSettingsProvider);
      // The sentinel is not installed on a desktop, so reading a message out is
      // not offered.
      expect(app.container.read(speechReadyProvider), isFalse);
    });
  });
}
