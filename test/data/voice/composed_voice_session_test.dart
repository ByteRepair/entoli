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
  var speaking = false;

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

  // The contract a real speaker keeps: what it has been handed and not
  // reported done, so silence means it is not speaking any more.
  void silent() {
    speaking = false;
    _signals.add(const SpeechSilent());
  }

  void fail(String m) => _signals.add(SpeechFailed(m));
}

List<VoiceEvent> collectEvents(ComposedVoiceSession session) {
  final events = <VoiceEvent>[];
  session.events.listen(events.add);
  return events;
}

/// A reply being said: handed to the speaker, which now reports itself as
/// speaking — the state under which what the listener picks up has to be
/// judged against what was said.
Future<void> _replyBeingSaid(
    ComposedVoiceSession session, _FakeSpeaker speaker) async {
  await session.speak("The weather looks nice today.");
  speaker.speaking = true;
}

void main() {
  group("ComposedVoiceSession", () {
    test("barge-in stops the speaker and forwards VoiceInterrupted", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      await _replyBeingSaid(session, speaker);
      listener.hear("stop talking please");
      await Future.delayed(Duration.zero);

      expect(speaker.stopCount, 1);
      expect(events.single, isA<VoiceInterrupted>(),
          reason: "the turn above aborts on this, as any barge-in");
      await session.dispose();
    });

    test("an echo of the reply is neither sent nor treated as an interruption",
        () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      await _replyBeingSaid(session, speaker);
      listener.interrupt();
      listener.hear("weather looks nice today");
      await Future.delayed(Duration.zero);

      expect(speaker.stopCount, 0,
          reason: "the phone hearing itself cuts nothing off");
      expect(events, isEmpty);
      await session.dispose();
    });

    test("onset alone interrupts nothing", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      await _replyBeingSaid(session, speaker);
      listener.interrupt();
      listener.interrupt();
      await Future.delayed(Duration.zero);

      expect(events, isEmpty);
      expect(speaker.stopCount, 0);
      await session.dispose();
    });

    test("with nothing being said, starting to talk is not a barge-in", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker()..speaking = true;
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      listener.hear("hello there");
      listener.interrupt();
      await Future.delayed(Duration.zero);

      // Nothing has been handed to the speaker, so whatever was heard cannot
      // be its own voice coming back — it goes through like anyone else's.
      expect(speaker.stopCount, 0);
      expect(events.single, isA<VoiceHeard>());
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

    test("silence empties the echo window", () async {
      final listener = _FakeListener();
      final speaker = _FakeSpeaker();
      final session = ComposedVoiceSession(listener, speaker);
      final events = collectEvents(session);

      await _replyBeingSaid(session, speaker);
      speaker.silent();
      await Future.delayed(Duration.zero);
      expect(events.single, isA<VoiceFellSilent>());

      // The very same words now arrive with nothing being said behind them.
      listener.hear("the weather looks nice today");
      await Future.delayed(Duration.zero);

      expect(events.last, isA<VoiceHeard>());
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

  group("isEcho", () {
    test("the same words back are an echo", () {
      expect(isEcho("The weather looks nice today.",
          "Hello there! The weather looks nice today."), isTrue);
    });

    test("case and punctuation do not hide one", () {
      expect(isEcho("WEATHER, LOOKS NICE", "the weather looks nice"), isTrue);
    });

    test("half the words shared still reads as one", () {
      expect(isEcho("weather nice today", "the weather looks nice today"),
          isTrue);
    });

    test("words that were not said are someone talking", () {
      expect(
          isEcho("what is the weather tomorrow",
              "the weather looks nice today"),
          isFalse);
    });

    test("nothing said yet is never an echo", () {
      expect(isEcho("anything at all", ""), isFalse);
    });
  });
}
