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

  /// A listener that has started, and everything it has said since. The four
  /// lines were at the head of every test here.
  Future<(AndroidSpeechRecognizer, List<VoiceEvent>)> listening(
      WidgetTester tester) async {
    final recognizer = AndroidSpeechRecognizer();
    addTearDown(recognizer.dispose);
    final events = <VoiceEvent>[];
    recognizer.events.listen(events.add);
    await tester.pump();
    return (recognizer, events);
  }

  testWidgets("listening asks to start", (tester) async {
    await listening(tester);
    wasAsked("startRecognition");
  });

  testWidgets("what is heard arrives; an empty result is nothing",
      (tester) async {
    final (recognizer, events) = await listening(tester);

    await incoming("heard", "hello there");
    await incoming("heard", "   ");
    await tester.pump();

    expect(events.single,
        isA<VoiceHeard>().having((e) => e.text, "text", "hello there"));
  });

  /// A room with nothing happening in it, reported long enough for the gate to
  /// have measured it and be entitled to refuse something.
  Future<void> room(double rms) async {
    for (var i = 0; i < 10; i++) {
      await incoming("rms", rms);
    }
  }

  testWidgets("loudness is measured against the room, not against a scale",
      (tester) async {
    final recognizer = AndroidSpeechRecognizer();
    addTearDown(recognizer.dispose);
    await tester.pump();

    await room(6.0);
    expect(recognizer.level.value, 0,
        reason: "a room at any level is the level nothing is happening at");

    await incoming("rms", 14.0);
    expect(recognizer.level.value, greaterThan(0.9));
  });

  testWidgets("what never rose above the room was not said to the phone",
      (tester) async {
    final (recognizer, events) = await listening(tester);

    await room(0.0);
    await incoming("interrupted");
    await incoming("rms", 1.0);
    await incoming("heard", "a fan, transcribed");
    await tester.pump();
    expect(events.whereType<VoiceHeard>(), isEmpty);

    await incoming("interrupted");
    await incoming("rms", 9.0);
    await incoming("heard", "somebody talking");
    await tester.pump();
    expect(events.whereType<VoiceHeard>().single.text, "somebody talking");
  });

  testWidgets("the bar follows the person, not only the room", (tester) async {
    final (recognizer, events) = await listening(tester);

    await room(0.0);
    await incoming("interrupted");
    await incoming("rms", 20.0);
    await incoming("heard", "somebody talking");
    await tester.pump();
    expect(events.whereType<VoiceHeard>().length, 1);

    // Well clear of the room, and a fifth of what this person sounds like.
    await incoming("interrupted");
    await incoming("rms", 5.0);
    await incoming("heard", "the next room over");
    await tester.pump();
    expect(events.whereType<VoiceHeard>().length, 1);
  });

  testWidgets("nothing is refused before the room has been measured",
      (tester) async {
    final (recognizer, events) = await listening(tester);

    // The first thing anyone says may be the first thing the microphone ever
    // heard, and a floor seeded from a voice is a bar above the voice that set
    // it.
    await incoming("rms", 8.0);
    await incoming("heard", "the first thing said");
    await tester.pump();

    expect(events.whereType<VoiceHeard>().single.text, "the first thing said");
  });

  testWidgets("a shut microphone is not the room, and is not measured",
      (tester) async {
    final (recognizer, _) = await listening(tester);

    await room(0.0);
    await recognizer.setListening(false);
    expect(recognizer.level.value, 0);

    // What the service reports on its way out of a cancelled session. Measured,
    // it would be a room nobody is in.
    await incoming("rms", 9.0);
    expect(recognizer.level.value, 0);
  });

  testWidgets("a session can open with the microphone shut", (tester) async {
    final recognizer = AndroidSpeechRecognizer(listening: false);
    addTearDown(recognizer.dispose);
    await tester.pump();

    // Opening a capture and closing it again is a real start and stop of the
    // device, and the microphone indicator flashing for nothing.
    expect(invoked.where((call) => call.method == "startRecognition"), isEmpty);
  });

  testWidgets("releasing the talk button asks for the sentence it was held for",
      (tester) async {
    final (recognizer, events) = await listening(tester);

    await recognizer.setListening(false, finish: true);
    expect(invoked.last.arguments, {"on": false, "finish": true});

    // The gate is not asked about it: holding a button down and speaking is not
    // something to second-guess by loudness.
    await room(0.0);
    await incoming("rms", 0.5);
    await incoming("heard", "what was said while it was held");
    await tester.pump();
    expect(events.whereType<VoiceHeard>().single.text,
        "what was said while it was held");
  });

  testWidgets("a recognition error fails the listener", (tester) async {
    final (recognizer, events) = await listening(tester);

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
