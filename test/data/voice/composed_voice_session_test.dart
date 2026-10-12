import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/voice/voice_strategies.dart";
import "package:agent_chat/domain/voice.dart";

class _FakeListener implements Listener {
  _FakeListener();
  final _events = StreamController<VoiceEvent>.broadcast();

  @override
  final level = ValueNotifier(0.0);

  var listening = true;
  var finished = 0;
  var disposed = false;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> setListening(bool on, {bool finish = false}) async {
    listening = on;
    if (!on && finish) finished++;
  }



  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }

  void hear(String text) => _events.add(VoiceHeard(text));
  void fail(String m) => _events.add(VoiceFailed(m));
}

class _FakeSpeaker implements Speaker {
  _FakeSpeaker();
  final _signals = StreamController<SpeechSignal>.broadcast();
  final spoken = <String>[];
  var stopCount = 0;
  var disposed = false;

  @override
  Stream<SpeechSignal> get signals => _signals.stream;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _signals.close();
  }

  void silent() => _signals.add(const SpeechSilent());

  void fail(String m) => _signals.add(SpeechFailed(m));
}

List<VoiceEvent> collectEvents(ComposedVoiceSession session) {
  final events = <VoiceEvent>[];
  session.events.listen(events.add);
  return events;
}

void main() {
  group("ComposedVoiceSession", () {

    test("a shut microphone says nothing, whatever the engine flushes",
        () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);
      await session.setListening(true);

      await session.setListening(false);
      // What a cancelled recognition session hands back on its way out, and
      // what sherpa's worker decodes from audio it already had — words nobody
      // spoke into a microphone that is off.
      listener.hear("the reply, half transcribed");
      await Future.delayed(Duration.zero);

      expect(events, isEmpty);
      await session.dispose();
    });

    test("a session opens shut and says nothing until it is asked to", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      listener.hear("nobody asked for this");
      await Future.delayed(Duration.zero);
      expect(events, isEmpty);

      await session.setListening(true);
      listener.hear("now they did");
      await Future.delayed(Duration.zero);
      // Forwarded unchanged.
      expect(events.whereType<VoiceHeard>().single.text, "now they did");
      await session.dispose();
    });

    test("a finish keeps the one sentence it was held for", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);
      await session.setListening(true);

      await session.setListening(false, finish: true);
      expect(listener.finished, 1);

      listener.hear("what was said while it was held");
      await Future.delayed(Duration.zero);
      expect(events.whereType<VoiceHeard>().single.text,
          "what was said while it was held");

      // One, and only the one that was asked for.
      listener.hear("and whatever came after");
      await Future.delayed(Duration.zero);
      expect(events.whereType<VoiceHeard>().length, 1);
      await session.dispose();
    });

    test("a failure arrives whatever the microphone is doing", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);
      await session.setListening(true);

      await session.setListening(false);
      listener.fail("The microphone could not be read.");
      await Future.delayed(Duration.zero);

      expect(events.whereType<VoiceFailed>().single.message,
          "The microphone could not be read.");
      await session.dispose();
    });

    test("speaker silence becomes VoiceFellSilent", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);
      await session.setListening(true);

      speaker.silent();
      await Future.delayed(Duration.zero);

      expect(events, contains(const VoiceFellSilent()));

      // A speaker failure is re-published too, as the failure it was.
      speaker.fail("boom");
      await Future.delayed(Duration.zero);
      expect(events, contains(predicate<VoiceEvent>((e) =>
          e is VoiceFailed && e.message == "boom")));
      await session.dispose();
    });

    test("speak and stopSpeaking reach the speaker", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);

      await session.speak("a sentence");
      await session.stopSpeaking();

      expect(speaker.spoken, ["a sentence"]);
      expect(speaker.stopCount, 1);
      await session.dispose();
    });

    test("with no listener, level is a dead notifier and setListening is a no-op",
        () async {
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(null, speaker);

      expect(session.level.value, 0);
      await session.setListening(false); // does not throw
      await session.dispose();
    });

    test("dispose disposes both halves", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);

      await session.dispose();

      expect(listener.disposed, isTrue);
      expect(speaker.disposed, isTrue);
    });
  });

}
