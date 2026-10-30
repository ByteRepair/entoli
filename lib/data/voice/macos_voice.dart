import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "android_voice.dart";

/// Voice mode on macOS: Apple's own engines — on-device `SFSpeechRecognizer`
/// and `AVSpeechSynthesizer`, behind the channel file iOS shares — beside the
/// sherpa catalog the other desktops run. That is [AndroidVoice]'s shape
/// exactly, routed per half, so a system recognizer with a downloaded voice
/// works, and the reverse; what differs is only which sentinels the engines
/// stand for, how long their languages take to sweep, and that a Mac has no
/// store engines for the settings page to point at.
///
/// Recognition is asked on-device only, as on iOS: a language the Mac cannot
/// hear without Apple's servers is not offered.
class MacosVoice extends AndroidVoice {
  MacosVoice(super.store, super.cacheDir);

  @override
  bool get hasEngineInstalls => false;

  @override
  ({String recognition, String speech}) get nativePicks =>
      (recognition: macosRecognition.id, speech: macosSpeech.id);

  /// The on-device intersection, as on iOS, and as slow to sweep.
  @override
  Future<List<VoiceLanguage>> systemLanguages() => nativeLanguages(
    timeout: const Duration(seconds: 10),
    failure: "the Mac would not say what it can hear and speak",
  );
}
