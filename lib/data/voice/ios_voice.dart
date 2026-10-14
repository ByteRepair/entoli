import "android_voice.dart";
import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "voice_strategies.dart";

/// Voice mode on iOS: Apple's own engines behind the same native contract
/// `VoiceChannel.kt` answers on Android — the [NativeSpeechRecognizer] and
/// [NativeTextToSpeech] strategies are shared, so this class is only the
/// routing and the probe. Recognition is the Speech framework asked
/// on-device and synthesis the system's voice; there is no sherpa here and
/// nothing is downloaded, which is why a pick naming a downloaded model is a
/// settings file carried from another platform — the installed set refuses
/// it before `start` ever runs.
///
/// The Speech framework is asked on-device only, so the invariant every
/// platform states aloud — nothing said is sent anywhere the typed
/// conversation is not — holds by construction: a language Apple cannot hear
/// on-device is not offered, not fallen back over a network rung the way
/// Android's ladder would.
class IosVoice extends Voice {
  const IosVoice();

  @override
  bool get hasModelCatalog => false;

  @override
  ({String recognition, String speech}) get nativePicks =>
      (recognition: iosRecognition.id, speech: iosSpeech.id);

  @override
  Future<NativeVoiceEngines> systemEngines() => probeNativeEngines();

  /// What Apple's engines can hear and speak **on-device**, which is the
  /// narrower answer than Android's synthesiser-only list — the slower one
  /// too, hence the longer wait: the sweep is a recognizer per supported
  /// locale. A locale either half cannot do without the network does not
  /// reach the picker.
  @override
  Future<List<VoiceLanguage>> systemLanguages() => nativeLanguages(
        timeout: const Duration(seconds: 10),
        failure: "the device would not say what it can hear and speak",
      );

  @override
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
    String? language,
  }) async {
    if (recognition?.isNative == false || !speech.isNative) {
      throw StateError("iOS has no downloaded voice models.");
    }
    // The grants are asked on the first listening turn, the way Android's
    // microphone grant is: a permission sheet nobody was pressing a button
    // for is worse than one at the Talk button. A refusal arrives over the
    // channel as a recognition error, which is the voice screen's to show.
    Listener? listener;
    if (recognition != null) {
      listener = NativeSpeechRecognizer(language: language);
    }
    // `speaker` has no meaning on the system voice and `language` is the
    // picker the settings page draws instead — the same shapes Android's
    // native halves take.
    return composeSession(
      listener,
      Future.value(NativeTextToSpeech(language: language)),
    );
  }
}