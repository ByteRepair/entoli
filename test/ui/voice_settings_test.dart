import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/model_registry.dart";
import "package:agent_chat/domain/voice.dart";
import "package:agent_chat/domain/voice_model.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/voice_settings.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";
import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  Future<void> pick(WidgetTester tester, {String? recognition, String? speech}) =>
      io(tester, () async {
        final settings = app.container.read(appSettingsProvider.notifier);
        if (recognition != null) await settings.setVoiceRecognitionModel(recognition);
        if (speech != null) await settings.setVoiceSpeechModel(speech);
      });

  Future<void> pumpVoice(WidgetTester tester) async {
    useWindow(tester, const Size(1200, 1600));
    await pumpSettings(tester, app, SettingsCategory.voice);
  }

  /// The downloads are On-device's: Voice only picks.
  Future<void> pumpOnDevice(WidgetTester tester) async {
    useWindow(tester, const Size(1200, 1600));
    await pumpSettings(tester, app, SettingsCategory.onDevice);
  }

  /// What a voice picker's catalog offers, on-device and provider alike.
  Future<List<String>> offered(WidgetTester tester, String field) async {
    await openModelCatalog(tester, field: find.widgetWithText(LabelledField, field));
    final labels = catalogLabels(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    return labels;
  }

  testWidgets("the Voice page downloads nothing", (tester) async {
    app = TestApp.create();
    await pumpVoice(tester);

    expect(find.byType(VoiceModelTile), findsNothing);
  });

  testWidgets("every model is listed whether it is downloaded or not",
      (tester) async {
    app = TestApp.create();
    await pumpOnDevice(tester);

    await scrollTo(tester, find.text("Whisper tiny"));
    await scrollTo(tester, find.text("Kokoro"));
    // Nothing is installed, so every row offers the download.
    expect(find.byTooltip("Download"), findsWidgets);
    expect(find.byTooltip("Delete"), findsNothing);
  });

  testWidgets("a multilingual model wears the badge and an English one does not",
      (tester) async {
    app = TestApp.create();
    await pumpOnDevice(tester);
    await scrollTo(tester, find.text("Moonshine tiny"));

    final whisper = find.ancestor(
        of: find.text("Whisper tiny"), matching: find.byType(VoiceModelTile));
    final moonshine = find.ancestor(
        of: find.text("Moonshine tiny"), matching: find.byType(VoiceModelTile));
    expect(
        find.descendant(of: whisper, matching: find.text("Multilingual")),
        findsOneWidget);
    expect(
        find.descendant(of: moonshine, matching: find.text("Multilingual")),
        findsNothing);
  });

  testWidgets("a row's specs are tags, and a speech model counts its voices",
      (tester) async {
    app = TestApp.create();
    await pumpOnDevice(tester);
    await scrollTo(tester, find.text("Kokoro"));

    Finder tag(String model, String label) => find.descendant(
        of: find.ancestor(
            of: find.text(model), matching: find.byType(VoiceModelTile)),
        matching: find.text(label));
    expect(tag("Kokoro", "82M params"), findsOneWidget);
    expect(tag("Kokoro", "103 voices"), findsOneWidget);
    expect(tag("Kokoro", "Apache-2.0"), findsOneWidget);
    expect(tag("Piper (Amy)", "1 voice"), findsOneWidget);
    // Its card gives neither, so neither is shown.
    expect(tag("Piper (Amy)", "MIT"), findsNothing);
  });

  testWidgets("downloading one puts it on the list of what can be picked",
      (tester) async {
    app = TestApp.create();
    await pumpOnDevice(tester);
    await scrollTo(tester, find.text("Whisper tiny"));

    final row = find.ancestor(
        of: find.text("Whisper tiny"), matching: find.byType(VoiceModelTile));
    await tester.tap(find.descendant(of: row, matching: find.byTooltip("Download")));
    await settleIo(tester);

    expect(app.container.read(installedVoiceModelsProvider),
        contains("whisper-tiny"));
    expect(find.descendant(of: row, matching: find.byTooltip("Delete")),
        findsOneWidget);
  });

  testWidgets("the pickers offer what is downloaded and say so when nothing is",
      (tester) async {
    app = TestApp.create();
    await pumpVoice(tester);
    await openModelCatalog(tester,
        field: find.widgetWithText(LabelledField, "Recognition model"));
    expect(find.text("No transcription models"), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    app.dispose();
    app = TestApp.create(voiceModels: const {"whisper-tiny"});
    await pumpVoice(tester);
    expect(await offered(tester, "Recognition model"), contains("On-device · whisper-tiny"));
    expect(await offered(tester, "Speech model"),
        isNot(contains("On-device · whisper-tiny")));
  });

  testWidgets("a provider's speech model is picked beside the device's, with a voice name",
      (tester) async {
    app = TestApp.create(voiceModels: const {"piper-en_US-amy"});
    ModelCatalog.notifier.value = ModelCatalog.parse(jsonEncode({
      testProviderId: {
        "models": {
          "tts-x": {
            "modalities": {"input": ["text"], "output": ["audio"]},
          },
        },
      },
    }));
    addTearDown(() => ModelCatalog.notifier.value = ModelCatalog.empty);
    await io(tester, () => app.seedProviders(const [testProvider]));
    await pumpVoice(tester);

    expect(await offered(tester, "Speech model"),
        containsAll(["On-device · piper-en_US-amy", "Test · tts-x"]));
    await pickModel(tester, "Test · tts-x",
        field: find.widgetWithText(LabelledField, "Speech model"));

    final settings = app.container.read(appSettingsProvider);
    expect((settings.voiceSpeechProviderId, settings.voiceSpeechModelId),
        (testProviderId, "tts-x"));
    expect(app.container.read(speechReadyProvider), isTrue);
    // A provider's voice is named, not numbered.
    expect(find.text("Voice 1"), findsNothing);
    expect(find.text("None sent"), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(app.voice.speakingWith, isA<SpeakThrough>());
  });

  testWidgets("deleting the model that was picked unpicks it", (tester) async {
    app = TestApp.create(voiceModels: const {"whisper-tiny"});
    await pick(tester, recognition: "whisper-tiny");
    await pumpOnDevice(tester);
    await scrollTo(tester, find.text("Whisper tiny"));

    final row = find.ancestor(
        of: find.text("Whisper tiny"), matching: find.byType(VoiceModelTile));
    await tester.tap(find.descendant(of: row, matching: find.byTooltip("Delete")));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, "Delete"));
    await settleIo(tester);

    // Left picked it would be voice mode failing to start with nothing on
    // screen to say why.
    expect(app.container.read(appSettingsProvider).voiceRecognitionModelId, isNull);
    expect(app.voiceModels.deleted, ["whisper-tiny"]);
  });

  /// Scoped to the section: the categories panel beside it has a tile called
  /// Voice, which is not the field this is about.
  Finder voicePicker() => find.descendant(
        of: find.byType(VoiceSection),
        matching: find.text("Voice"),
      );

  testWidgets("a model with one voice still has the field", (tester) async {
    app = TestApp.create(voiceModels: const {"piper-en_US-amy"});
    await pick(tester, speech: "piper-en_US-amy");
    await pumpVoice(tester);

    // A list of one, so that picking a speech model is not also a change to
    // which fields the page has.
    expect(voicePicker(), findsOneWidget);
    expect(find.text("Voice 1"), findsOneWidget);
    expect(find.text("Voice 2"), findsNothing);
  });

  testWidgets("touch to speak is offered, and off until it is asked for",
      (tester) async {
    app = TestApp.create();
    await pumpVoice(tester);

    final toggle = find.widgetWithText(SwitchListTile, "Touch to speak");
    await scrollTo(tester, toggle);
    expect(app.container.read(appSettingsProvider).voicePushToTalk, isFalse);

    await tester.tap(toggle);
    await settleIo(tester);
    expect(app.container.read(appSettingsProvider).voicePushToTalk, isTrue);
  });

  testWidgets("a platform with no voice does not list the category",
      (tester) async {
    app = TestApp.create(voice: FakeVoice(available: false));
    useWindow(tester, const Size(1200, 1600));
    await app.pump(tester, const SettingsPage());

    expect(tile("Voice"), findsNothing);
    expect(tile("Memory"), findsOneWidget);
  });

  testWidgets("nor opens it when asked for it by name", (tester) async {
    app = TestApp.create(voice: FakeVoice(available: false));
    useWindow(tester, const Size(1200, 1600));
    await app.pump(tester,
        const SettingsPage(initialCategory: SettingsCategory.voice, focus: true));

    expect(find.widgetWithText(AppBar, "Settings"), findsOneWidget);
    expect(find.text("Voice mode"), findsNothing);
  });

  testWidgets("the preview reads one line in the voice picked", (tester) async {
    app = TestApp.create(voiceModels: const {"piper-en_US-amy"});
    await pick(tester, speech: "piper-en_US-amy");
    await pumpVoice(tester);

    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();

    expect(app.voice.session!.spoken.join(" "), contains("how are you"));
    // No microphone: this is a preview of a voice, not voice mode.
    expect(app.voice.listeningWith, isNull);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
  });

  testWidgets("the preview is dead until the model is downloaded",
      (tester) async {
    app = TestApp.create();
    await pick(tester, speech: "piper-en_US-amy");
    await pumpVoice(tester);

    expect(enabled(tester, buttonTipped("Hear this voice")), isFalse);
  });

  group("on Android", () {
    /// An Android: the catalog and the system engines beside it, [hears] and
    /// [speaks] as which of them the device has. `nativeVoice` is what the
    /// harness seeds the usable set and the engines' presence from — the same
    /// answer `main` builds the provider with.
    Future<void> pumpAndroid(
      WidgetTester tester, {
      bool hears = true,
      bool speaks = true,
    }) async {
      app = TestApp.create(
        voice: FakeVoice(),
        nativeVoice: NativeVoiceEngines(recognition: hears, speech: speaks),
      );
      await pumpVoice(tester);
    }

    testWidgets("the system engines are picked, beside what is downloaded",
        (tester) async {
      await pumpAndroid(tester);

      // Defaulted into both picks.
      expect(find.text("Android system"), findsNWidgets(2));
      expect(await offered(tester, "Recognition model"),
          contains("On-device · android-recognition"));
      // With both engines there is nothing to explain above them.
      expect(find.textContaining("This device has nothing to"), findsNothing);
    });

    testWidgets("an unset recognizer is named as the setting it is",
        (tester) async {
      await pumpAndroid(tester, hears: false);

      // Downloaded but never set as the system's voice-input service is the
      // same thing to do about it as not installed: named, with where to set
      // it — and the catalog below is the other way out.
      expect(find.textContaining("voice-input service"), findsOneWidget);
      expect(find.textContaining("Settings > On-device"), findsOneWidget);
      expect(find.textContaining("FUTO Voice Input"), findsOneWidget);
    });

    testWidgets("a missing synthesiser is named, with somewhere to get one",
        (tester) async {
      await pumpAndroid(tester, speaks: false);

      expect(find.textContaining("nothing to speak with"), findsOneWidget);
      final link = find.textContaining("RHVoice");
      expect(link, findsOneWidget);
      // The half it does have is not advertised as missing.
      expect(find.textContaining("FUTO Voice Input"), findsNothing);

      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(app.linkOpener.opened.single.host, "f-droid.org");
    });

    testWidgets("with neither engine both halves are named", (tester) async {
      await pumpAndroid(tester, hears: false, speaks: false);

      expect(find.textContaining("nothing to hear with"), findsOneWidget);
      expect(find.textContaining("nothing to speak with"), findsOneWidget);
      expect(find.textContaining("RHVoice"), findsOneWidget);
      expect(find.textContaining("FUTO Voice Input"), findsOneWidget);
    });

    /// An Android with both engines, its sentinels picked, and [speaks] as what
    /// the synthesiser says it can speak.
    Future<void> pumpNative(
      WidgetTester tester, {
      List<VoiceLanguage> speaks = const [],
    }) async {
      app = TestApp.create(
        voice: FakeVoice()..languages = speaks,
        nativeVoice: const NativeVoiceEngines(recognition: true, speech: true),
      );
      await pick(tester,
          recognition: nativeRecognition.id, speech: nativeSpeech.id);
      await pumpVoice(tester);
    }

    testWidgets("the language is picked here, and written down", (tester) async {
      await pumpNative(tester, speaks: const [
        VoiceLanguage(tag: "el-GR", name: "Greek"),
        VoiceLanguage(tag: "en-GB", name: "English"),
      ]);

      // Nothing picked is the device's own, which is what it did before there
      // was a field.
      expect(app.container.read(appSettingsProvider).voiceLanguage, isNull);
      expect(find.text("Device language"), findsOneWidget);

      await tester.tap(find.widgetWithText(LabelledField, "Language"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Greek").last);
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).voiceLanguage, "el-GR");
    });

    testWidgets("a device that names no languages is offered no field",
        (tester) async {
      // A picker holding only "the device's own" is a control that cannot be
      // used to say anything.
      await pumpNative(tester);

      expect(find.text("Language"), findsNothing);
    });

    testWidgets("a language this device has no entry for is kept",
        (tester) async {
      // A settings file carried off another phone. Reset silently, it would be
      // the one that knew what the tag meant.
      await pumpNative(tester, speaks: const [
        VoiceLanguage(tag: "en-GB", name: "English"),
      ]);
      await io(tester,
          () => app.container.read(appSettingsProvider.notifier)
              .setVoiceLanguage("el-GR"));
      await settleIo(tester);

      expect(find.text("el-GR"), findsOneWidget);
    });
  });

  group("on iOS", () {
    /// An iPhone: Apple's engines are the whole of what can listen and speak,
    /// so the sentinels default into the picks and the page draws the mode and
    /// the language and nothing else. `assistantGesture: false` is what takes
    /// the Assistant section away where there is no gesture to configure.
    Future<void> pumpIos(
      WidgetTester tester, {
      List<VoiceLanguage> speaks = const [],
    }) async {
      app = TestApp.create(
        voice: FakeVoice(hasEngineInstalls: false, hasModelCatalog: false)
          ..nativePicks = (recognition: iosRecognition.id, speech: iosSpeech.id)
          ..languages = speaks,
        nativeVoice: const NativeVoiceEngines(recognition: true, speech: true),
        assistantGesture: false,
      );
      await pumpVoice(tester);
    }

    testWidgets("only speaking has a choice: a provider's voice", (tester) async {
      await pumpIos(tester,
          speaks: const [VoiceLanguage(tag: "en-GB", name: "English")]);

      // Listening through a provider needs Silero, which iOS has not got.
      expect(find.text("Recognition model"), findsNothing);
      expect(find.text("Speech model"), findsOneWidget);
      expect(find.text("Whisper tiny"), findsNothing);
      expect(find.text("Android system"), findsNothing);
      expect(find.text("Assistant"), findsNothing);
      expect(find.text("Touch to speak"), findsOneWidget);
      expect(find.text("Language"), findsOneWidget);
      expect(find.text("Device language"), findsOneWidget);
    });

    testWidgets("no language both engines can do is no field", (tester) async {
      await pumpIos(tester);

      expect(find.text("Language"), findsNothing);
      expect(find.text("Touch to speak"), findsOneWidget);
    });
  });

  testWidgets("a provider's models make voice mode ready where sherpa can listen",
      (tester) async {
    Future<bool> ready({required bool sherpa}) async {
      app = TestApp.create(voice: FakeVoice(hasModelCatalog: sherpa));
      await io(tester, () async {
        await app.seedProviders(const [testProvider]);
        final settings = app.container.read(appSettingsProvider.notifier);
        await settings.setVoiceRecognition((providerId: testProviderId, modelId: "stt"));
        await settings.setVoiceSpeech((providerId: testProviderId, modelId: "tts"));
      });
      final picks = voicePicks(app.container.read(appSettingsProvider), app.backend);
      expect(picks.speaking, isA<SpeakThrough>());
      expect(picks.hearing is HearThrough, sherpa);
      final ready = app.container.read(voiceReadyProvider);
      app.dispose();
      return ready;
    }

    expect(await ready(sherpa: true), isTrue);
    // iOS: nothing to cut the microphone into utterances with.
    expect(await ready(sherpa: false), isFalse);
    app = TestApp.create();
  });

  testWidgets("a downloaded model has no language to pick: it is one already",
      (tester) async {
    app = TestApp.create(voiceModels: const {"piper-en_US-amy"})
      ..voice.languages = const [VoiceLanguage(tag: "el-GR", name: "Greek")];
    await pick(tester, speech: "piper-en_US-amy");
    await pumpVoice(tester);

    expect(find.text("Language"), findsNothing);
  });
}
