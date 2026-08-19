import "dart:async";

import "package:flutter/foundation.dart" show ValueListenable, ValueNotifier;
import "package:record/record.dart";

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
/// when the user starts talking over a reply (the session stops the speaker on
/// this), and [VoiceFailed] on a fault it cannot recover from.
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
  Future<void> setListening(bool on);

  Future<void> dispose();
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

/// A [VoiceSession] composed of a [Listener] and a [Speaker], neither knowing
/// about the other. The session wires barge-in — a [VoiceInterrupted] from the
/// listener stops the speaker — and forwards the rest of both halves' events
/// unchanged. Each `Voice` picks its own pair in `start`, which is what makes
/// `AndroidVoice` a dozen lines and gives read-aloud a speak-only session for
/// free.
class ComposedVoiceSession implements VoiceSession {
  ComposedVoiceSession(this._listener, this._speaker) {
    _listener?.events.listen(_onListener);
    _speaker.signals.listen(_onSpeaker);
  }

  final Listener? _listener;
  final Speaker _speaker;

  final _events = StreamController<VoiceEvent>.broadcast();
  final _levelOf = ValueNotifier(0.0);

  void _onListener(VoiceEvent event) {
    switch (event) {
      case VoiceHeard():
        _events.add(event);
      case VoiceInterrupted():
        // Only when there is a reply to talk over. Unguarded, every utterance
        // the user opens their mouth for would abort the running turn.
        if (!_speaker.speaking) return;
        // The speech stops here rather than in the controller, so the moment
        // the user starts is the moment it goes quiet — whatever the controller
        // then decides about the turn.
        unawaited(_speaker.stop());
        _events.add(const VoiceInterrupted());
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
        _events.add(const VoiceFellSilent());
      case SpeechFailed(:final message):
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
  Future<void> setListening(bool on) => _listener?.setListening(on) ?? Future.value();

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
