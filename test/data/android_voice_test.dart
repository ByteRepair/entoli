import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/voice/android_voice.dart";
import "package:agent_chat/data/voice/voice_strategies.dart" show SpeechFailed, SpeechSignal, SpeechSilent;
import "package:agent_chat/domain/voice.dart";

// The system engines behind a mock `agent_chat/voice`: what Dart asks for and
// what it does with what Kotlin says back. The real channel has no
// implementation on a test host, so every test installs one and drives the
// bridge through `handlePlatformMessage` — the same door Kotlin's `send`
// knocks on.
const channel = MethodChannel("agent_chat/voice");

void main() {
  final invoked = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      invoked.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    invoked.clear();
  });

  Future<void> incoming(String method, [Object? arguments]) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );

  void wasAsked(String method) => expect(
      invoked.where((call) => call.method == method), isNotEmpty,
      reason: "$method was never asked");

  testWidgets("listening asks to start", (tester) async {
    final recognizer = AndroidSpeechRecognizer();
    addTearDown(recognizer.dispose);
    await tester.pump();
    wasAsked("startRecognition");
  });

  testWidgets("what is heard arrives; an empty result is nothing",
      (tester) async {
    final recognizer = AndroidSpeechRecognizer();
    addTearDown(recognizer.dispose);
    final events = <VoiceEvent>[];
    recognizer.events.listen(events.add);
    await tester.pump();

    await incoming("heard", "hello there");
    await incoming("heard", "   ");
    await tester.pump();

    expect(events.single,
        isA<VoiceHeard>().having((e) => e.text, "text", "hello there"));
  });

  testWidgets("loudness follows the rms the service reports", (tester) async {
    final recognizer = AndroidSpeechRecognizer();
    addTearDown(recognizer.dispose);
    await tester.pump();

    await incoming("rms", 4.0);
    expect(recognizer.level.value, closeTo(0.5, 0.001));
  });

  testWidgets("a recognition error fails the listener", (tester) async {
    final recognizer = AndroidSpeechRecognizer();
    addTearDown(recognizer.dispose);
    final events = <VoiceEvent>[];
    recognizer.events.listen(events.add);
    await tester.pump();

    await incoming("recognitionError", "Recognition failed (error 7).");
    await tester.pump();

    expect(
        events.single,
        isA<VoiceFailed>()
            .having((e) => e.message, "message", "Recognition failed (error 7)."));
  });

  testWidgets("speech waits until the engine says it can speak",
      (tester) async {
    final tts = AndroidTextToSpeech();
    addTearDown(tts.dispose);
    await tester.pump();

    await tts.speak("held");
    expect(invoked.where((call) => call.method == "speak"), isEmpty,
        reason: "an engine that has not answered holds everything");
    expect(tts.speaking, isTrue);

    await incoming("speechReady");
    await tester.pump();

    final speak = invoked.lastWhere((call) => call.method == "speak");
    expect(speak.arguments, {"text": "held", "generation": 0});
  });

  testWidgets("every done counts its utterance down to silence",
      (tester) async {
    final tts = AndroidTextToSpeech();
    addTearDown(tts.dispose);
    final signals = <SpeechSignal>[];
    tts.signals.listen(signals.add);
    await tester.pump();

    await incoming("speechReady");
    await tts.speak("one");
    await tts.speak("two");
    await tester.pump();

    await incoming("speechDone", 0);
    expect(signals, isEmpty, reason: "the queue still holds a sentence");

    await incoming("speechDone", 0);
    await tester.pump();
    expect(signals, [const SpeechSilent()]);
  });

  testWidgets("a done naming a stopped batch is not counted", (tester) async {
    final tts = AndroidTextToSpeech();
    addTearDown(tts.dispose);
    final signals = <SpeechSignal>[];
    tts.signals.listen(signals.add);
    await tester.pump();

    await incoming("speechReady");
    await tts.speak("interrupted mid-word");
    await tts.stop();
    await tester.pump();

    await incoming("speechDone", 0);
    await tester.pump();
    expect(signals, isEmpty);

    await tts.speak("after");
    await incoming("speechDone", 1);
    await tester.pump();
    expect(signals, [const SpeechSilent()]);
  });

  testWidgets("one dropped utterance is not a broken engine", (tester) async {
    final tts = AndroidTextToSpeech();
    addTearDown(tts.dispose);
    final signals = <SpeechSignal>[];
    tts.signals.listen(signals.add);
    await tester.pump();

    await incoming("speechReady");
    await tts.speak("flaky");
    await incoming("speechUtteranceError", 0);
    await tester.pump();
    expect(signals, [const SpeechSilent()],
        reason: "the queue drained around the failure");

    // A success clears the count, so failures straddling one are tolerated.
    await tts.speak("fine");
    await incoming("speechDone", 0);
    await tts.speak("flaky again");
    await incoming("speechUtteranceError", 0);
    await tester.pump();
    expect(signals.whereType<SpeechFailed>(), isEmpty);
  });

  testWidgets("three failures in a row are said", (tester) async {
    final tts = AndroidTextToSpeech();
    addTearDown(tts.dispose);
    final signals = <SpeechSignal>[];
    tts.signals.listen(signals.add);
    await tester.pump();

    await incoming("speechReady");
    for (final text in ["one", "two", "three"]) {
      await tts.speak(text);
    }
    for (var i = 0; i < 3; i++) {
      await incoming("speechUtteranceError", 0);
    }
    await tester.pump();

    expect(signals.whereType<SpeechFailed>().single.message,
        "Speech playback keeps failing.");
    expect(tts.speaking, isFalse,
        reason: "nothing is held any more once the engine is written off");
  });

  testWidgets("an engine that never starts is said, not waited for",
      (tester) async {
    final tts = AndroidTextToSpeech();
    addTearDown(tts.dispose);
    final signals = <SpeechSignal>[];
    tts.signals.listen(signals.add);

    await tts.speak("nobody will say this");
    await tester.pump(const Duration(seconds: 5));

    expect(signals.whereType<SpeechFailed>(), isNotEmpty);
    expect(tts.speaking, isFalse);
  });
}
