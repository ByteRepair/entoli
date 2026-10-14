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

  /// Nothing installable is what the missing-engine block offers, which is
  /// why it is Android's: a denied permission here surfaces where it
  /// happened, as the start's own failure on the voice screen, and the next
  /// launch re-probes.
  @override
  bool get hasSystemEngines => false;

  @override
  bool get hasModelCatalog => false;

  @override
  ({String recognition, String speech}) get nativePicks =>
      (recognition: iosRecognition.id, speech: iosSpeech.id);

  @override
  Future<NativeVoiceEngines> systemEngines() async {
    try {
      final answer = await voiceChannel.invokeMapMethod<String, bool>("engines");
      if (answer == null) return NativeVoiceEngines.none;
      return NativeVoiceEngines(
        recognition: answer["recognition"] ?? false,
        speech: answer["speech"] ?? false,
      );
    } catch (_) {
      return NativeVoiceEngines.none;
    }
  }

  /// What Apple's engines can hear and speak **on-device**, which is the
  /// narrower answer than Android's synthesiser-only list: a locale either
  /// half cannot do without the network does not reach the picker.
  @override
  Future<List<VoiceLanguage>> systemLanguages() async {
    try {
      final answer = await voiceChannel
          .invokeListMethod<Map<Object?, Object?>>("languages")
          .timeout(const Duration(seconds: 10));
      return [
        for (final language in answer ?? const <Map<Object?, Object?>>[])
          if (language["tag"] case final String tag when tag.isNotEmpty)
            VoiceLanguage(tag: tag, name: language["name"] as String? ?? tag),
      ];
    } catch (e) {
      voiceFailed("the device would not say what it can hear and speak: $e");
      return const [];
    }
  }

  @override
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
    String? language,
  }) async {
    // one that fails loudly.
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