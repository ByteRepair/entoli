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
/// recognition. Emits [VoiceHeard] for transcribed utterances, [VoiceInterrupted]
/// on detected speech onset, and [VoiceFailed] on a fault it cannot recover
/// from. Onset alone interrupts nothing — the session decides, from what was
/// heard and what is being said, whether someone actually talked over a reply.
///
/// Extracted from `SherpaVoice` so a session can compose a [Listener] and a
/// [Speaker] independently: sherpa's pair on the desktops, the system engines'
/// on Android, and a null [Listener] for reading one message out. The session
/// wires the two together; neither knows about the other.
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

/// Everything a [Listener] with a microphone behind it is made of, which turned
/// out to be everything except the engine: the event stream, the level, and the
/// [LoudnessGate] that decides whether what was heard was meant for the phone.
///
/// It exists because the gate did not. It was written for the system recogniser
/// and lived in that class, so the desktops answered the fan and the television
/// for as long as Android had stopped — and the same was true of the rest of
/// this before it: two implementations of one thing, one of which was written.
/// Held here, an engine gets it by being a listener rather than by remembering
/// to be one. What a subclass supplies is only what its engine gives it —
/// readings through [measured], onset through [began], words through [heard] —
/// and which [LoudnessGate] those readings are on.
abstract class MicrophoneListener implements Listener {
  MicrophoneListener(this.gate);

  /// Whether what was heard was meant for the phone. One gate serves both
  /// engines and is handed in rather than built here only so a test can watch
  /// one: there is nothing scale-dependent left in it to configure.
  final LoudnessGate gate;

  /// Single-subscription, not broadcast: a failure to start is emitted before
  /// anything has subscribed, and a broadcast controller drops it on the floor.
  /// That was voice mode sitting there showing a microphone that was never
  /// going to hear anything.
  final _events = StreamController<VoiceEvent>();
  final _levelOf = ValueNotifier(0.0);

  /// Whether the microphone is open. What a shut microphone is allowed to *say*
  /// is [ComposedVoiceSession]'s; what is here is what only this side knows — a
  /// reading taken while it is shut is not a reading of the room.
  bool listening = true;

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

  /// The engine says an utterance has started. Forwarded whatever it turns out
  /// to have been: onset alone interrupts nothing, and the session is what
  /// decides whether someone talked over a reply.
  void began() {
    if (closed) return;
    _events.add(const VoiceInterrupted());
  }

  /// An utterance, transcribed — emitted only if it was loud enough to have
  /// been meant for the phone.
  void heard(String text) {
    if (closed) return;
    final spoken = gate.spoken();
    final words = text.trim();
    // A cough is a speech segment to a detector and nothing to a conversation.
    if (words.isNotEmpty && spoken) _events.add(VoiceHeard(words));
  }

  void fail(String message) {
    if (!closed) _events.add(VoiceFailed(message));
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

  /// Whether a reply is being said right now. What makes a [VoiceInterrupted]
  /// from the listener a barge-in rather than someone simply starting to talk:
  /// voice activity is detected at the start of every utterance, and only the
  /// ones landing on top of a reply are an interruption of anything.
  bool get speaking;

  Future<void> speak(String text);

  /// Drop what is queued and stop what is playing. What talking over the reply
  /// amounts to, and what leaving the screen does.
  Future<void> stop();

  Future<void> dispose();
}

/// How many sentences in a row a speaker may lose before the engine, rather
/// than the sentence, is what failed.
///
/// **One dropped sentence is not a broken engine.** A synthesiser refuses the
/// odd utterance, a voice comes back with no samples in it, a file will not
/// play; reported up, each of those ends voice mode over a sentence that could
/// have been skipped. But an engine that has stopped working answers every
/// sentence that way, and a reply nobody can hear with a session that will not
/// say so is worse.
///
/// It was the system synthesiser's rule and only its own, so on the desktops
/// one bad sentence still ended the session. A count is small enough to have
/// been written twice and was instead written once — which is the same shape as
/// the gate above it.
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
/// about the other. The session wires barge-in — confirmed, not assumed: the
/// recogniser cannot tell its own playback from the room acoustically, so a
/// reply is cut off only once words arrive that were not just said (see
/// [isEcho]) — and forwards the rest of both halves' events unchanged. Each
/// `Voice` picks its own pair in `start`, which is what makes `AndroidVoice` a
/// dozen lines and gives read-aloud a speak-only session for free.
class ComposedVoiceSession implements VoiceSession {
  ComposedVoiceSession(this._listener, this._speaker, {bool listening = true}) {
    _listening = listening;
    _listener?.events.listen(_onListener);
    _speaker.signals.listen(_onSpeaker);
  }

  final Listener? _listener;
  final Speaker _speaker;

  final _events = StreamController<VoiceEvent>.broadcast();
  final _levelOf = ValueNotifier(0.0);

  /// What has been handed to the speaker since it last went quiet — what the
  /// recogniser may be hearing back. Kept to its tail: an echo can only be of
  /// recent speech.
  static const _saidWindow = 1200;
  final _said = StringBuffer();

  /// What [setListening] was last told, and whether one more utterance is still
  /// wanted after it was shut. Held here rather than in each [Listener] because
  /// it is one rule about what the session is allowed to say, and a listener
  /// that forgot it would be silently back to the bug below.
  bool _listening = true;
  bool _finishing = false;

  /// **A shut microphone says nothing.** Neither engine stops on the instant it
  /// is asked to: a cancelled `SpeechRecognizer` session flushes what it had,
  /// and audio already handed to sherpa's worker decodes after the recorder is
  /// released. Forwarded, that arrives as words nobody spoke into a microphone
  /// that is off — and landing on a reply still being read, it is not an echo
  /// of what was just said, so it is a barge-in, so the speaker stops and the
  /// turn is aborted. That is the Mute button stopping the answer, which is not
  /// what it promises.
  ///
  /// The exception is the utterance a `finish` asked for, which is the release
  /// of a touch-to-speak button: the microphone closed because the sentence was
  /// over, not to throw it away.
  bool _wanted(VoiceEvent event) {
    if (_listening) return true;
    if (event is! VoiceHeard || !_finishing) return false;
    _finishing = false;
    return true;
  }

  void _onListener(VoiceEvent event) {
    // A failure is the session's whatever the microphone is doing, since it is
    // why it is doing nothing.
    if (event is! VoiceFailed && !_wanted(event)) return;
    switch (event) {
      case VoiceHeard(:final text):
        // Onset alone interrupts nothing: every sentence said trips voice
        // activity on its way out of the speaker. What was heard decides — if
        // it reads like the reply coming back it is dropped as echo; if not,
        // someone talked over the reply, which is Stop and then listen to me,
        // in one gesture. Nothing said yet is nothing that could come back, so
        // it passes straight through.
        if (_speaker.speaking && _said.isNotEmpty) {
          if (!isEcho(text, _said.toString())) {
            unawaited(_speaker.stop());
            _events.add(const VoiceInterrupted());
          }
          return;
        }
        _events.add(event);
      case VoiceInterrupted():
        // Never forwarded on its own: without words behind it there is no
        // telling the user from the phone's own voice. The Stop button remains
        // the instant way to cut a reply off.
        break;
      case VoiceFailed():
        _events.add(event);
      case VoiceFellSilent():
        // The listener never emits this; silence is the speaker's to report.
        break;
    }
  }

  void _onSpeaker(SpeechSignal signal) {
    switch (signal) {
      case SpeechSilent():
        _said.clear();
        _events.add(const VoiceFellSilent());
      case SpeechFailed(:final message):
        _said.clear();
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
    // Before the call rather than after it: what the engine does with the
    // request takes a platform hop, and anything it flushes in between is
    // exactly what this is here to drop.
    _listening = on;
    _finishing = !on && finish;
    return _listener?.setListening(on, finish: finish) ?? Future.value();
  }

  @override
  Future<void> speak(String text) async {
    _said..write(" ")..write(text);
    if (_said.length > _saidWindow) {
      final said = _said.toString();
      _said..clear()..write(said.substring(said.length - _saidWindow));
    }
    await _speaker.speak(text);
  }

  @override
  Future<void> stopSpeaking() async {
    _said.clear();
    await _speaker.stop();
  }

  @override
  Future<void> dispose() async {
    await _listener?.dispose();
    await _speaker.dispose();
    await _events.close();
    _levelOf.dispose();
  }
}

/// Whether [heard] reads like [spoken] coming back off the speaker rather than
/// the person the microphone is pointed at. The two are one acoustic event to a
/// recogniser — the reply is in the room with the user — and what separates
/// them is content: we know exactly what was just said, so words substantially
/// made of those same words are an echo, and anything else is someone talking.
/// Garbled transcriptions of it can still slip past this; the Stop button under
/// the orb remains the way to cut a reply off for certain.
bool isEcho(String heard, String spoken) {
  final said = words(spoken);
  if (said.isEmpty) return false;
  final pickedUp = words(heard);
  if (pickedUp.isEmpty) return false;
  return pickedUp.intersection(said).length / pickedUp.length >= 0.5;
}

// Letters and numbers are kept and everything else separates: `\w` would strip
// every non-Latin script to nothing, and a Greek or Japanese echo must still be
// recognised as one.
Set<String> words(String text) => text
    .toLowerCase()
    .split(RegExp(r"[^\p{L}\p{N}]+", unicode: true))
    .where((word) => word.isNotEmpty)
    .toSet();
