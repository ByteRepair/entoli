import "package:flutter/foundation.dart" show ValueListenable;

import "voice_model.dart";

/// Listening and speaking, on whatever this platform can do it with. Like
/// [Shell] for commands: desktop and Android have the models and the
/// microphone, a browser has neither, and [available] is the whole of the
/// difference — false takes the voice button off the composer rather than
/// leaving one that fails when pressed.
///
/// Nothing here knows about a conversation. A voice turn is an ordinary turn:
/// what this port does is hand text up and take text down, and
/// `ui/voice/voice_controller.dart` is what puts either into a chat.
abstract class Voice {
  const Voice();

  bool get available => true;

  /// Load the models and open the microphone. Throws if a model is not
  /// installed or will not load, which the caller shows rather than swallows —
  /// a voice screen that opens silent is worse than one that says why.
  ///
  /// **With no [recognition] model there is nothing to listen with**: no
  /// microphone is opened and the session only speaks. That is the button
  /// under a message, which reads one message out and is not voice mode.
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
  });
}

/// A session: a microphone that is open, models that are loaded, and whatever
/// is queued to be said. One at a time, and it holds a worker isolate, so
/// whoever starts one has to [VoiceSession.dispose] it.
abstract class VoiceSession {
  Stream<VoiceEvent> get events;

  /// How loud the microphone is, 0 to 1, for the circle to follow. A listenable
  /// rather than an event because it changes every audio frame, and the
  /// transcript above the circle has no business rebuilding for it.
  ValueListenable<double> get level;

  /// Open or shut the microphone, which is what pausing is. A release rather
  /// than a stream left running and thrown away: paused has to mean the device
  /// is no longer recording, which is what the system's own microphone
  /// indicator will say either way. Nothing to listen with makes it a no-op.
  Future<void> setListening(bool on);

  /// Say [text], after anything already queued. Sentence-sized chunks: the
  /// first is being read while the rest of the reply is still being written.
  Future<void> speak(String text);

  /// Drop what is queued and stop what is playing. What the user talking over
  /// the reply amounts to, and what leaving the screen does.
  Future<void> stopSpeaking();

  Future<void> dispose();
}

sealed class VoiceEvent {
  const VoiceEvent();
}

/// An utterance, transcribed. Empty transcriptions never reach here — a cough
/// is a speech segment to a VAD and nothing to a conversation.
class VoiceHeard extends VoiceEvent {
  const VoiceHeard(this.text);

  final String text;
}

/// The user started talking over the reply. The engine has already stopped
/// speaking by the time this arrives; it is up to the controller whether the
/// turn is worth aborting too.
class VoiceInterrupted extends VoiceEvent {
  const VoiceInterrupted();
}

/// Everything queued has been said.
class VoiceFellSilent extends VoiceEvent {
  const VoiceFellSilent();
}

/// Something went wrong mid-session — the microphone was taken, a model threw.
/// The session stays alive; what it can still do is up to what failed.
class VoiceFailed extends VoiceEvent {
  const VoiceFailed(this.message);

  final String message;
}

/// The web's voice: there isn't one. See issue #58 — the browser's own speech
/// APIs are the way this platform gets voice mode, and shipping sherpa's 14 MB
/// of WebAssembly into a build that would run it single-threaded is not.
class UnavailableVoice extends Voice {
  const UnavailableVoice();

  @override
  bool get available => false;

  @override
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
  }) async =>
      throw UnsupportedError("Voice mode is not available in a browser.");
}
