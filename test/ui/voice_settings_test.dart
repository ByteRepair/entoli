import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/voice.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/voice_settings.dart";

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
    testWidgets("there is no catalog to download from", (tester) async {
      app = TestApp.create(
        voice: FakeVoice(downloadsModels: false),
        nativeVoice: const NativeVoiceEngines(recognition: true, speech: true),
      );
      await pumpVoice(tester);

      // The system engines are the whole of what there is, so a list of models
      // to fetch would be a list of things this platform cannot run.
      expect(find.text("Whisper tiny"), findsNothing);
      expect(find.text("Kokoro"), findsNothing);
      expect(find.byTooltip("Download"), findsNothing);
      expect(find.text("Android system"), findsWidgets);
    });

    testWidgets("a missing engine is named, with somewhere to get one",
        (tester) async {
      app = TestApp.create(
        voice: FakeVoice(downloadsModels: false),
        nativeVoice: const NativeVoiceEngines(recognition: false, speech: true),
      );
      await pumpVoice(tester);

      // Nothing to fall back on here, so an empty picker on its own would be a
      // dead end rather than one install away from working.
      expect(find.textContaining("nothing to hear with"), findsOneWidget);
      final link = find.textContaining("FUTO Voice Input");
      expect(link, findsOneWidget);
      // The half it does have is not advertised as missing.
      expect(find.textContaining("RHVoice"), findsNothing);

      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(app.linkOpener.opened.single.host, "voiceinput.futo.tech");
    });

    testWidgets("with both engines there is nothing to explain", (tester) async {
      app = TestApp.create(
        voice: FakeVoice(downloadsModels: false),
        nativeVoice: const NativeVoiceEngines(recognition: true, speech: true),
      );
      await pumpVoice(tester);

      expect(find.textContaining("This device has nothing to"), findsNothing);
    });

    testWidgets("the on-device switch belongs to the system service alone",
        (tester) async {
      app = TestApp.create(
        voice: FakeVoice(downloadsModels: false),
        nativeVoice: const NativeVoiceEngines(recognition: true, speech: true),
        voiceModels: voiceModelIds,
      );
      await pumpVoice(tester);

      final toggle = find.text("Only listen on this device");
      await scrollTo(tester, toggle);
      expect(toggle, findsOneWidget);

      // A downloaded model has no network to keep away from, so the switch
      // would be a promise about something that was never in question.
      await pick(tester, recognition: voiceModelPair.recognition);
      await tester.pumpAndSettle();
      expect(find.text("Only listen on this device"), findsNothing);
    });

    testWidgets("the flat privacy claim is not made for the system service",
        (tester) async {
      app = TestApp.create(
        voice: FakeVoice(downloadsModels: false),
        nativeVoice: const NativeVoiceEngines(recognition: true, speech: true),
      );
      await pumpVoice(tester);

      // The service may answer over the network, so the header says what the
      // switch below is for rather than claiming nothing leaves the device.
      expect(find.textContaining("may reach the network"), findsOneWidget);
      expect(find.textContaining("is sent anywhere the typed"), findsNothing);
    });

    testWidgets("switching it on is stored", (tester) async {
      app = TestApp.create(
        voice: FakeVoice(downloadsModels: false),
        nativeVoice: const NativeVoiceEngines(recognition: true, speech: true),
      );
      await pumpVoice(tester);

      final toggle =
          find.widgetWithText(SwitchListTile, "Only listen on this device");
      await scrollTo(tester, toggle);
      await tester.tap(toggle);
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).voiceOnDeviceOnly, isTrue);
    });
  });
}
