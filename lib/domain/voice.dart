import "dart:typed_data";

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

/// What a WAV of one utterance says, asked of a provider's transcription model.
typedef Transcribe = Future<String> Function(Uint8List wav);

/// A sentence as audio, asked of a provider's speech model: WAV where the
/// provider honours the request for it, whatever it sent otherwise.
typedef Synthesize = Future<Uint8List> Function(String text);

/// What a session listens with: a model on the device, or a provider's.
sealed class Hearing {
  const Hearing();
}

class HearOnDevice extends Hearing {
  const HearOnDevice(this.model);
  final RecognitionModel model;
}

class HearThrough extends Hearing {
  const HearThrough(this.transcribe);
  final Transcribe transcribe;
}

/// What a session speaks with, the same way.
sealed class Speaking {
  const Speaking();
}

class SpeakOnDevice extends Speaking {
  const SpeakOnDevice(this.model);
  final SpeechModel model;
}

class SpeakThrough extends Speaking {
  const SpeakThrough(this.synthesize);
  final Synthesize synthesize;
}

/// Listening and speaking, on whatever this platform can do it with: sherpa's
/// models on the desktops and Android, the system's engines on the Apples and
/// beside sherpa on Android.
///
/// Nothing here knows about a conversation. A voice turn is an ordinary turn:
/// what this port does is hand text up and take text down, and
/// `ui/voice/voice_controller.dart` is what puts either into a chat.
abstract class Voice {
  const Voice();

  /// Whether this platform has engine installs the settings page's
  /// missing-engine block can point at, which is what the block is drawn
  /// from: the block is Android's store engines alone, and on a platform
  /// without any the block would be a lie. Asked of the platform rather than
  /// of the probe — the block is about a phone the probe's own answer may
  /// say nothing for.
  bool get hasEngineInstalls => false;

  /// Whether this platform has the downloadable catalog beside the device's
  /// own engines. False where the engines are the whole of what can listen
  /// and speak, which is what takes the pickers and the download lists off
  /// the settings page: a picker of one says nothing, and a catalogue with
  /// nothing to fetch is a lie.
  ///
  /// It is also whether a provider's transcription model can listen here:
  /// both are sherpa, which cuts the microphone into utterances. Speaking
  /// through a provider needs only a player, and is everywhere.
  bool get hasModelCatalog => true;

  /// The native picks this platform's engines stand for — what a true answer
  /// from [systemEngines] puts in the installed set, and what a null setting
  /// defaults to. Null where there are none: the desktops whose engines are
  /// all downloaded.
  ({String recognition, String speech})? get nativePicks => null;

  /// Which of the device's own engines are there, for the platforms that have
  /// any. Asked once at startup, where the answer joins the installed models —
  /// a sentinel pick is usable on exactly the same terms as a downloaded one,
  /// so there is one set to consult rather than a second question beside it.
  Future<NativeVoiceEngines> systemEngines() async => NativeVoiceEngines.none;

  /// Which languages the device's own engines can be asked for, and empty
  /// where there are none to ask. **Only the system engines have this
  /// question**: a downloaded model is one language already, so picking the
  /// language there is picking the model — which is why [start]'s `language`
  /// reaches Android and nothing else.
  Future<List<VoiceLanguage>> systemLanguages() async => const [];

  /// Load the models and open the microphone. Throws if a model is not
  /// installed or will not load, which the caller shows rather than swallows —
  /// a voice screen that opens silent is worse than one that says why.
  ///
  /// **With no [hearing] there is nothing to listen with**: no
  /// microphone is opened and the session only speaks. That is the button
  /// under a message, which reads one message out and is not voice mode.
  ///
  /// **A session opens with the microphone shut**, whatever it was built with,
  /// and something has to ask for it — which is the whole of the turn-taking
  /// above this. Opening a capture at the door and closing it again for the
  /// first turn would be a real start and stop of the device and the system's
  /// own microphone indicator flashing for nothing.
  ///
  /// [language] is a BCP-47 tag the system engines are asked to hear and speak
  /// in, null being whatever the device is set to. See [systemLanguages].
  Future<VoiceSession> start({
    Hearing? hearing,
    required Speaking speaking,
    int speaker = 0,
    String? language,
  });
}

/// A language the device's own engines can be asked for: a BCP-47 [tag] and
/// the [name] the device itself calls it by. The name is composed over there
/// rather than from a table here — it is the platform that knows what the user
/// reads Greek as.
class VoiceLanguage {
  const VoiceLanguage({required this.tag, required this.name});

  final String tag;
  final String name;
}

/// Which of the device's own engines are actually there, which is what the
/// Android-system sentinels resolve to. Asked of the platform rather than
/// inferred from it: `TextToSpeech` needs an engine, and a phone with no
/// Google apps on it may have none. Recognition is the system's own
/// voice-input pick, made and installed — the only configuration the
/// framework gives a recognizer the microphone in. This is what used to be
/// asked as "is this Android" — the real question was always this one, and
/// off Android it answers itself.
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
