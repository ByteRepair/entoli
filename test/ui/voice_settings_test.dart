import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/voice.dart";
import "package:agent_chat/domain/voice_model.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/voice_settings.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";
import "../harness.dart";

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

  testWidgets("every model is listed whether it is downloaded or not",
      (tester) async {
    app = TestApp.create();
    await pumpVoice(tester);

    await scrollTo(tester, find.text("Whisper tiny"));
    await scrollTo(tester, find.text("Kokoro"));
    // Nothing is installed, so every row offers the download.
    expect(find.byTooltip("Download"), findsWidgets);
    expect(find.byTooltip("Delete"), findsNothing);
  });

  testWidgets("a multilingual model wears the badge and an English one does not",
      (tester) async {
    app = TestApp.create();
    await pumpVoice(tester);

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

  testWidgets("downloading one puts it on the list of what can be picked",
      (tester) async {
    app = TestApp.create();
    await pumpVoice(tester);

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
    expect(find.text("Nothing downloaded yet."), findsNWidgets(2));

    app.dispose();
    app = TestApp.create(voiceModels: const {"whisper-tiny"});
    await pumpVoice(tester);
    expect(find.text("Nothing downloaded yet."), findsOneWidget);
  });

  testWidgets("deleting the model that was picked unpicks it", (tester) async {
    app = TestApp.create(voiceModels: const {"whisper-tiny"});
    await pick(tester, recognition: "whisper-tiny");
    await pumpVoice(tester);

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

  testWidgets("a model with several offers them", (tester) async {
    app = TestApp.create(voiceModels: const {"kokoro-multi-lang"});
    await pick(tester, speech: "kokoro-multi-lang");
    await pumpVoice(tester);

    expect(voicePicker(), findsOneWidget);
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

  testWidgets("a browser is not offered it: there is no microphone to hold",
      (tester) async {
    app = TestApp.create(voice: FakeVoice(available: false));
    await pumpVoice(tester);

    expect(find.text("Touch to speak"), findsNothing);
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

    testWidgets("the catalog draws beside the system engines", (tester) async {
      await pumpAndroid(tester);

      expect(find.text("Whisper tiny"), findsOneWidget);
      expect(find.text("Android system"), findsWidgets);
    });

    testWidgets("an unset recognizer is named as the setting it is",
        (tester) async {
      await pumpAndroid(tester, hears: false);

      // Downloaded but never set as the system's voice-input service is the
      // same thing to do about it as not installed: named, with where to set
      // it — and the catalog below is the other way out.
      expect(find.textContaining("voice-input service"), findsOneWidget);
      expect(find.textContaining("downloaded model"), findsOneWidget);
      expect(find.textContaining("FUTO Voice Input"), findsOneWidget);
    });

    testWidgets("with both engines there is nothing to explain", (tester) async {
      await pumpAndroid(tester);

      expect(find.textContaining("This device has nothing to"), findsNothing);
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

    /// An Android with both engines, its sentinels picked, and [speaks] as what
    /// the synthesiser says it can speak.
    Future<void> pumpNative(
      WidgetTester tester, {
      List<VoiceLanguage> speaks = const [],
    }) async {
      app = TestApp.create(
        voice: FakeVoice(downloadsModels: false)..languages = speaks,
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

  testWidgets("a downloaded model has no language to pick: it is one already",
      (tester) async {
    app = TestApp.create(voiceModels: const {"piper-en_US-amy"})
      ..voice.languages = const [VoiceLanguage(tag: "el-GR", name: "Greek")];
    await pick(tester, speech: "piper-en_US-amy");
    await pumpVoice(tester);

    expect(find.text("Language"), findsNothing);
  });
}
