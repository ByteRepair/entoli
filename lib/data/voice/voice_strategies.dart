import "dart:async";
import "dart:math" as math;

import "package:flutter/foundation.dart" show ValueListenable, ValueNotifier;
import "package:record/record.dart";

import "../../domain/loudness.dart";
import "../../domain/voice.dart";

/// The microphone, once the user has allowed it. `AudioRecorder` is the only
/// thing here that can ask for the grant, so both kinds of listener ask through
/// it: the sherpa one keeps the recorder and reads from it, while
/// `SpeechRecognizer` opens one of its own and throws this away, wanting only
/// the answer — it reports a missing grant as an error rather than asking, so
/// nothing on that path would ask at all.
Future<AudioRecorder> openMicrophone() async {
  final recorder = AudioRecorder();
  if (await recorder.hasPermission()) return recorder;
  recorder.dispose();
  throw StateError("Entoli was not allowed to use the microphone.");
}

/// The listening half of a voice session: a microphone, voice activity, and
/// recognition. Emits [VoiceHeard] for transcribed utterances and [VoiceFailed]
/// on a fault it cannot recover from.
abstract class Listener {
  Stream<VoiceEvent> get events;

  /// How loud the microphone is, 0 to 1, for the circle to follow.
  ValueListenable<double> get level;

  /// Open or shut the microphone. Nothing to listen with makes it a no-op.
  /// [finish] is [VoiceSession.setListening]'s: keep the utterance in progress
  /// rather than dropping it with the session.
  Future<void> setListening(bool on, {bool finish = false});

  Future<void> dispose();
}

/// Everything a [Listener] with a microphone behind it shares across engines:
/// the event stream, the level, and the [LoudnessGate] that decides whether
/// what was heard was meant for the phone. A subclass supplies readings
/// through [measured] and words through [heard].
abstract class MicrophoneListener implements Listener {
  MicrophoneListener(this.gate);

  /// Handed in only so a test can watch it.
  final LoudnessGate gate;

  /// Single-subscription, not broadcast: a failure to start is emitted before
  /// anything has subscribed, and a broadcast controller drops it on the floor.
  /// That was voice mode sitting there showing a microphone that was never
  /// going to hear anything.
  final _events = StreamController<VoiceEvent>();
  final _levelOf = ValueNotifier(0.0);

  /// Whether the microphone is open. False until something asks: a session
  /// opens shut. What a shut microphone is allowed to *say* is
  /// [ComposedVoiceSession]'s; what is here is what only this side knows — a
  /// reading taken while it is shut is not a reading of the room.
  bool listening = false;

  bool closed = false;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  ValueListenable<double> get level => _levelOf;

  /// The shared half of [setListening]: the microphone's state, and the gate
  /// and the level going quiet with it. Each engine does its own half around
  /// this.
  ///
  /// **The utterance is over whichever way this went**, and that is also what a
  /// `finish` needs. Nothing more is measured with the microphone shut, so the
  /// result that arrives after one — the sentence a touch-to-speak button was
  /// held for — is one the gate has nothing to judge on and lets through, which
  /// is the right answer for a sentence somebody deliberately spoke. Whether
  /// anyone asked for it at all is a different question, and
  /// [ComposedVoiceSession] is where it is answered.
  void asked(bool on) {
    listening = on;
    gate.quiet();
    _levelOf.value = 0;
  }

  /// One reading of how loud it is, on this gate's scale. Ignored with the
  /// microphone shut: what a cancelled engine reports on its way out is not the
  /// room this gate is measuring.
  void measured(double loudness) {
    if (closed || !listening) return;
    gate.measure(loudness);
    // Falls rather than drops, so the circle follows a voice instead of
    // flickering with it — and rounded, so a floor creeping by a hundredth does
    // not wake the orb at all: a `ValueNotifier` drops a write of what it
    // already holds, and this is on the audio path.
    final level = math.max(gate.level, _levelOf.value * _levelFall);
    _levelOf.value = (level * 100).round() / 100;
  }

  static const _levelFall = 0.8;

  /// An utterance, transcribed — emitted only if it was loud enough to have
  /// been meant for the phone. [judged] is an utterance the gate already let
  /// through when it ended, before it was sent away to be transcribed.
  void heard(String text, {bool judged = false}) {
    if (closed) return;
    final spoken = judged || gate.spoken();
    final words = text.trim();
    // A cough is a speech segment to a detector and nothing to a conversation.
    if (words.isEmpty) return;
    // The arm nothing draws: a turn that never happens, and no way to tell it
    // from a microphone that is not working.
    if (!spoken) {
      return voiceFailed("utterance refused: too quiet for this room");
    }
    _events.add(VoiceHeard(words));
  }

  void fail(String message) {
    if (closed) return;
    voiceFailed("listening failed: $message");
    _events.add(VoiceFailed(message));
  }

  /// The half of [dispose] that is the same either way, called once the engine
  /// has been let go.
  void disposeParts() {
    // Not awaited: on a single-subscription stream the future from close waits
    // for a listener to take the done event off the buffer, and a listener
    // nobody subscribed to — which is what disposing one without starting it
    // means — would hang there forever.
    unawaited(_events.close());
    _levelOf.dispose();
  }
}

/// A signal from the speaker that the queue has drained and nothing is still
/// being generated — the session forwards it as [VoiceFellSilent]. Distinct
/// from [VoiceEvent] because a speaker has nothing to say about hearing or
/// interruption, which are the listener's.
sealed class SpeechSignal {
  const SpeechSignal();
}

class SpeechSilent extends SpeechSignal {
  const SpeechSilent();
}

class SpeechFailed extends SpeechSignal {
  const SpeechFailed(this.message);
  final String message;
}

/// The speaking half: sentence-sized chunks queued and played. [speak] is
/// called per sentence; [stop] drops what is queued and stops what is playing.
/// [signals] carries the two things the session needs to know: silence (queue
/// drained, nothing pending) and failure.
abstract class Speaker {
  Stream<SpeechSignal> get signals;

  Future<void> speak(String text);

  /// Drop what is queued and stop what is playing. What talking over the reply
  /// amounts to, and what leaving the screen does.
  Future<void> stop();

  Future<void> dispose();
}

/// How many sentences in a row a speaker may lose before the engine, rather
/// than the sentence, is what failed: a synthesiser refuses the odd utterance,
/// but a broken one refuses every one.
class SpeechFailures {
  static const _budget = 3;

  int _run = 0;

  /// A sentence was said, which is what clears the run: three failures
  /// straddling one that worked are three separate sentences, not an engine.
  void spoke() => _run = 0;

  /// A sentence will not be. True once enough of them have gone in a row that
  /// the engine is what to report.
  bool dropped() => ++_run >= _budget;
}

/// A [VoiceSession] composed of a [Listener] and a [Speaker], neither knowing
/// about the other. It forwards both halves' events and owns one rule: what a
/// microphone that has been shut is still allowed to say.
class ComposedVoiceSession implements VoiceSession {
  ComposedVoiceSession(this._listener, this._speaker) {
    _listener?.events.listen(_onListener);
    _speaker.signals.listen(_onSpeaker);
  }

  final Listener? _listener;
  final Speaker _speaker;

  final _events = StreamController<VoiceEvent>.broadcast();
  final _levelOf = ValueNotifier(0.0);

  /// What [setListening] was last told, and whether one more utterance is still
  /// wanted after it was shut.
  bool _listening = false;
  bool _finishing = false;

  /// **A shut microphone says nothing.** Neither engine stops on the instant it
  /// is asked to: a cancelled `SpeechRecognizer` session flushes what it had,
  /// and audio already handed to sherpa's worker decodes after the recorder is
  /// released. Forwarded, that is words nobody spoke into a microphone that is
  /// off, landing in the middle of somebody else's turn.
  ///
  /// The exception is the utterance a `finish` asked for — mute, and letting go
  /// of the Talk button: the microphone closed because the sentence was over,
  /// not to throw it away.
  bool _wanted(VoiceEvent event) {
    if (_listening) return true;
    if (event is! VoiceHeard || !_finishing) {
      voiceLog(() => "dropped ${event.runtimeType}: the microphone is shut");
      return false;
    }
    _finishing = false;
    return true;
  }

  /// A failure is the session's whatever the microphone is doing, since it is
  /// why it is doing nothing. Everything else is [_wanted]'s to allow.
  void _onListener(VoiceEvent event) {
    if (event is VoiceFailed || _wanted(event)) _events.add(event);
  }

  void _onSpeaker(SpeechSignal signal) {
    switch (signal) {
      case SpeechSilent():
        _events.add(const VoiceFellSilent());
      case SpeechFailed(:final message):
        voiceFailed("speaking failed: $message");
        _events.add(VoiceFailed(message));
    }
  }

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  ValueListenable<double> get level {
    final listener = _listener;
    return listener != null ? listener.level : _levelOf;
  }

  @override
  Future<void> setListening(bool on, {bool finish = false}) {
    if (on == _listening) return Future.value();
    // Set before the call rather than after it: what the engine does with the
    // request takes a platform hop, and anything it flushes in between is
    // exactly what these are here to drop.
    _listening = on;
    _finishing = !on && finish;
    voiceLog(() => on ? "microphone open" : "microphone shut");
    return _listener?.setListening(on, finish: finish) ?? Future.value();
  }

  @override
  Future<void> speak(String text) => _speaker.speak(text);

  @override
  Future<void> stopSpeaking() => _speaker.stop();

  @override
  Future<void> dispose() async {
    await _listener?.dispose();
    await _speaker.dispose();
    await _events.close();
    _levelOf.dispose();
  }
}

/// How every `Voice.start` finishes: a speaker that refuses must not orphan
/// the listener, which holds a recorder, an isolate or a subscription.
Future<VoiceSession> composeSession(
  Listener? listener,
  Future<Speaker> speaker,
) async {
  try {
    return ComposedVoiceSession(listener, await speaker);
  } catch (_) {
    await listener?.dispose();
    rethrow;
  }
}
