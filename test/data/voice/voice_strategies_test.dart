import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/voice/voice_strategies.dart";
import "package:agent_chat/domain/loudness.dart";
import "package:agent_chat/domain/voice.dart";

/// An engine with nothing behind it, which is what a [MicrophoneListener] is
/// once its engine is taken away. Both real ones reach the gate, the level and
/// the event stream through exactly these calls, so what is asserted here is
/// asserted for the pair of them.
class _Engine extends MicrophoneListener {
  _Engine() : super(LoudnessGate());

  @override
  Future<void> setListening(bool on, {bool finish = false}) async => asked(on);

  @override
  Future<void> dispose() async {
    closed = true;
    disposeParts();
  }
}

/// A room at [amplitude], reported long enough for the gate to have measured it
/// and be entitled to refuse something.
void room(MicrophoneListener engine, double amplitude) {
  for (var i = 0; i < 20; i++) {
    engine.measured(decibels(amplitude));
  }
}

void main() {
  group("decibels", () {
    test("puts a microphone's own numbers on a scale with a room on it", () {
      // What the two ends of the range a listener actually sees look like.
      expect(decibels(1.0), closeTo(0, 0.001));
      expect(decibels(0.1), closeTo(-20, 0.001));
      expect(decibels(0.003), closeTo(-50.5, 0.1));
    });

    test("silence is a floor rather than negative infinity", () {
      // The gate subtracts and compares; an infinity poisons every reading
      // after it.
      expect(decibels(0), decibels(0.000001));
      expect(decibels(0).isFinite, isTrue);
    });
  });

  group("LoudnessGate", () {
    /// One utterance: a room, then something above it.
    bool utterance(
      LoudnessGate gate, {
      double floor = 0,
      required double peak,
    }) {
      for (var i = 0; i < 60; i++) {
        gate.measure(floor);
      }
      gate.measure(peak);
      return gate.spoken();
    }

    test("the first thing said always carries, whatever it was", () {
      // Nothing has been heard to compare it against, and a gate that refuses
      // on no evidence is a microphone that looks broken.
      expect(utterance(LoudnessGate(), peak: 1), isTrue);
    });

    test("what follows is judged against it", () {
      final gate = LoudnessGate();
      expect(utterance(gate, peak: 30), isTrue);
      expect(
        utterance(gate, peak: 5),
        isFalse,
        reason: "a television, next to somebody talking to the phone",
      );
      expect(
        utterance(gate, peak: 25),
        isTrue,
        reason: "the same person, a little quieter",
      );
    });

    test("a level set by the wrong thing corrects itself upward", () {
      final gate = LoudnessGate();
      // The television got there first, so it set the level.
      expect(utterance(gate, peak: 5), isTrue);
      // A real voice is louder than what set it, so it carries and takes over.
      expect(utterance(gate, peak: 30), isTrue);
      expect(utterance(gate, peak: 5), isFalse);
    });

    test("and downward, so one shout is not the bar for the session", () {
      final gate = LoudnessGate();
      expect(utterance(gate, peak: 100), isTrue);
      var carried = false;
      for (var i = 0; i < 40 && !carried; i++) {
        carried = utterance(gate, peak: 20);
      }
      expect(carried, isTrue);
    });

    test("no absolute number in it: the same story on any scale", () {
      // The bug this replaced: a fixed margin in the units `onRmsChanged`
      // reports, on a device that reports a narrower range than the documented
      // one. Nothing was ever loud enough, and voice mode answered nobody.
      for (final scale in [0.01, 1.0, 100.0]) {
        final gate = LoudnessGate();
        expect(utterance(gate, floor: -scale, peak: 30 * scale), isTrue);
        expect(utterance(gate, floor: -scale, peak: 5 * scale), isFalse);
      }
    });

    test("a floor is a minimum, so a long sentence cannot raise it", () {
      final gate = LoudnessGate();
      expect(utterance(gate, peak: 30), isTrue);
      // Held for far longer than the floor's own memory. An averaging floor
      // climbs into this and reports that nobody said anything.
      for (var i = 0; i < 300; i++) {
        gate.measure(30);
      }
      expect(gate.spoken(), isTrue);
    });
  });

  group("MicrophoneListener", () {
    test(
      "an engine is gated by being a listener, not by remembering to be",
      () async {
        final engine = _Engine();
        await engine.setListening(true);
        final heard = <String>[];
        engine.events
            .where((e) => e is VoiceHeard)
            .listen((e) => heard.add((e as VoiceHeard).text));

        // Loud enough to set the level, and trimmed on the way through.
        room(engine, 0.003);
        engine.measured(decibels(0.1));
        engine.heard("  somebody talking  ");
        await Future.delayed(Duration.zero);
        expect(heard, ["somebody talking"]);

        room(engine, 0.003);
        engine.measured(decibels(0.006));
        engine.heard("a television, two rooms away");
        await Future.delayed(Duration.zero);
        expect(heard, ["somebody talking"], reason: "and nothing more");

        await engine.dispose();
      },
    );

    test(
      "the level is against the room, and falls rather than drops",
      () async {
        final engine = _Engine();
        await engine.setListening(true);

        room(engine, 0.003);
        expect(
          engine.level.value,
          0,
          reason: "a room at any level is the level nothing is happening at",
        );

        engine.measured(decibels(0.2));
        expect(engine.level.value, 1);

        // The circle follows a voice instead of flickering with it.
        engine.measured(decibels(0.003));
        expect(engine.level.value, closeTo(0.8, 0.01));

        await engine.dispose();
      },
    );

    test("a shut microphone is not the room, and is not measured", () async {
      final engine = _Engine();
      await engine.setListening(true);

      room(engine, 0.003);
      await engine.setListening(false);
      expect(engine.level.value, 0);

      engine.measured(decibels(0.2));
      expect(engine.level.value, 0);

      await engine.dispose();
    });

    test("what a shut microphone flushes has nothing to be judged on", () async {
      final engine = _Engine();
      await engine.setListening(true);
      final heard = <String>[];
      engine.events
          .where((e) => e is VoiceHeard)
          .listen((e) => heard.add((e as VoiceHeard).text));

      // Said while a touch-to-speak button was held, or just before a mute.
      // Shutting the microphone is what ends the measuring, so the gate has
      // nothing left to refuse it on — which is the right answer for a sentence
      // somebody deliberately spoke. Whether anyone asked for it at all is
      // `ComposedVoiceSession`'s question, not this one.
      room(engine, 0.003);
      engine.measured(decibels(0.1));
      engine.heard("setting the level");
      room(engine, 0.003);
      engine.measured(decibels(0.006));
      await engine.setListening(false, finish: true);
      engine.heard("said while it was held");
      await Future.delayed(Duration.zero);

      expect(heard, ["setting the level", "said while it was held"]);
      await engine.dispose();
    });

    test("opening again forgets what was measured before it was shut", () async {
      final engine = _Engine();
      await engine.setListening(true);
      final heard = <String>[];
      engine.events
          .where((e) => e is VoiceHeard)
          .listen((e) => heard.add((e as VoiceHeard).text));

      // A loud utterance measured before the microphone was shut. What is said
      // after it is opened again is judged on its own, not on that.
      room(engine, 0.003);
      engine.measured(decibels(0.2));
      engine.heard("setting the level");
      room(engine, 0.003);
      engine.measured(decibels(0.2));
      await engine.setListening(false);
      await engine.setListening(true);

      room(engine, 0.003);
      engine.measured(decibels(0.006));
      engine.heard("a television, two rooms away");
      await Future.delayed(Duration.zero);
      expect(heard, ["setting the level"]);

      await engine.dispose();
    });
  });

  group("SpeechFailures", () {
    test("two failures are not broken, three in a row is", () {
      final failures = SpeechFailures();
      expect(failures.dropped(), isFalse);
      expect(failures.dropped(), isFalse);

      // The third in a row with nothing said between them is said.
      expect(failures.dropped(), isTrue);
    });

    test("a sentence that was said clears the run", () {
      final failures = SpeechFailures();
      failures.dropped();
      failures.dropped();
      failures.spoke();
      expect(
        failures.dropped(),
        isFalse,
        reason: "failures straddling one that worked are separate sentences",
      );
    });
  });
}
