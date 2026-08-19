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
  var disposed = false;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> setListening(bool on) async => listening = on;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }

  void hear(String text) => _events.add(VoiceHeard(text));
  void interrupt() => _events.add(const VoiceInterrupted());
  void fail(String m) => _events.add(VoiceFailed(m));
}

class _FakeSpeaker implements Speaker {
  _FakeSpeaker();
  final _signals = StreamController<SpeechSignal>.broadcast();
  final spoken = <String>[];
  var stopCount = 0;
  var disposed = false;

  @override
  var speaking = true;

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
    test("barge-in stops the speaker and forwards VoiceInterrupted", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      listener.interrupt();
      await Future.delayed(Duration.zero);

      expect(speaker.stopCount, 1);
      expect(events, contains(const VoiceInterrupted()));
      await session.dispose();
    });

    test("with nothing being said, starting to talk is not a barge-in", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker()..speaking = false;
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      listener.interrupt();
      await Future.delayed(Duration.zero);

      // Voice activity opens every utterance, and the controller aborts the
      // running turn on a VoiceInterrupted — so an unguarded one would kill
      // the turn the user is waiting on every time they spoke.
      expect(speaker.stopCount, 0);
      expect(events, isEmpty);
      await session.dispose();
    });

    test("VoiceHeard is forwarded unchanged", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      listener.hear("hello there");
      await Future.delayed(Duration.zero);

      expect(events, contains(predicate<VoiceEvent>((e) =>
          e is VoiceHeard && e.text == "hello there")));
      await session.dispose();
    });

    test("speaker silence becomes VoiceFellSilent", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      speaker.silent();
      await Future.delayed(Duration.zero);

      expect(events, contains(const VoiceFellSilent()));
      await session.dispose();
    });

    test("a speaker failure becomes VoiceFailed", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

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
