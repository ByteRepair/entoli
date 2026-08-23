import "package:flutter/foundation.dart"
    show ValueListenable, debugPrint, kDebugMode;

import "voice_model.dart";

/// A voice-mode failure, or a decision that silently stops one from answering.
///
/// **Not gated on [kDebugMode].** Every way voice mode goes wrong arrives as
/// "it did not answer me" — a microphone nothing opened, a recogniser that
/// never ended the utterance, a gate that refused it — and they are
/// indistinguishable from the outside. A release build is the one a user is
/// running when they report it, so it has to be able to say which.
///
/// **Never what was said.** A transcript is the conversation: it is in
/// `conv.jsonl` already, where the user put it, and a second copy in a device
/// log is somebody's speech somewhere nobody chose. Assume every line here is
/// pasted into an issue unread.
void voiceFailed(String what) => debugPrint("voice: $what");

/// What voice mode is doing, in debug builds only. A log of every transition is
/// unreadable and nobody sends it; what earns a line above is the arm nothing
/// draws.
///
/// Taken as a closure so a release build does not build the string it is about
/// to throw away — some of these are on the path an audio frame takes.
void voiceLog(String Function() action) {
  if (kDebugMode) debugPrint("voice: ${action()}");
}

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

  /// Whether listening and speaking here are done with models the user
  /// downloads. True on the desktops, where sherpa-onnx is the only engine
  /// there is; false on Android, which uses the system's own and so has no
  /// catalog to draw, nothing to fetch and nothing taking up space.
  bool get downloadsModels => true;

  /// Which of the device's own engines are there, for the platforms that have
  /// any. Asked once at startup, where the answer joins the installed models —
  /// a sentinel pick is usable on exactly the same terms as a downloaded one,
  /// so there is one set to consult rather than a second question beside it.
  Future<NativeVoiceEngines> systemEngines() async => NativeVoiceEngines.none;

  /// Load the models and open the microphone. Throws if a model is not
  /// installed or will not load, which the caller shows rather than swallows —
  /// a voice screen that opens silent is worse than one that says why.
  ///
  /// **With no [recognition] model there is nothing to listen with**: no
  /// microphone is opened and the session only speaks. That is the button
  /// under a message, which reads one message out and is not voice mode.
  ///
  /// **A session opens with the microphone shut**, whatever it was built with,
  /// and something has to ask for it — which is the whole of the turn-taking
  /// above this. Opening a capture at the door and closing it again for the
  /// first turn would be a real start and stop of the device and the system's
  /// own microphone indicator flashing for nothing.
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
  });
}

/// Which of the device's own engines are actually there, which is what the
/// Android-system sentinels resolve to. Asked of the platform rather than
/// inferred from it: `SpeechRecognizer` needs a recognition service installed
/// and `TextToSpeech` needs an engine, and a phone with no Google apps on it
/// may have neither. This is what used to be asked as "is this Android" — the
/// real question was always this one, and off Android it answers itself.
class NativeVoiceEngines {
  const NativeVoiceEngines({required this.recognition, required this.speech});

  final bool recognition;
  final bool speech;

  /// Nothing of the platform's own: every platform that is not Android, and an
  /// Android one whose channel said nothing.
  static const none = NativeVoiceEngines(recognition: false, speech: false);
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

  /// Open or shut the microphone. A release rather than a stream left running
  /// and thrown away: shut has to mean the device is no longer recording, which
  /// is what the system's own microphone indicator will say either way. Nothing
  /// to listen with makes it a no-op.
  ///
  /// **Asking for what it is already doing is a no-op too**, so a caller does
  /// not have to keep its own copy of the answer to avoid a platform call — the
  /// turn-taking above this runs after every state change and most of them
  /// change nothing here.
  ///
  /// Shutting it drops whatever was being said into it, which is right where
  /// the microphone is closing because it is no longer the user's turn to
  /// speak. [finish] keeps that last utterance instead, and is what the user
  /// saying they have finished talking asks for — mute, and letting go of the
  /// Talk button.
  Future<void> setListening(bool on, {bool finish = false});

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
