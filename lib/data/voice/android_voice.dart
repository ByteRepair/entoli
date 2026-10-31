import "dart:async";

import "package:flutter/services.dart";

import "../../domain/loudness.dart";
import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "../../domain/voice_model_store.dart";
import "../model_host/model_process.dart";
import "remote_speaker.dart";
import "sherpa_voice.dart";
import "voice_strategies.dart";

/// Voice mode on Android: the device's own `TextToSpeech` and
/// `SpeechRecognizer` where their sentinel is what was picked, and sherpa-onnx
/// where a downloaded model was — the same halves the desktops use, composed
/// through a [SherpaVoice] this holds, since sherpa's native code ships in the
/// APK. Each half routes on its own pick. See "The system engines" in
/// AGENTS.md for why sherpa is the fallback here.
///
/// `MacosVoice` is this over Apple's engines. The `Native*` classes below are
/// the native contract `ios_voice.dart` shares too.
class AndroidVoice extends Voice {
  AndroidVoice(VoiceModelStore store, String cacheDir, ModelProcess process)
    : _sherpa = SherpaVoice(store, cacheDir, process);

  /// The sherpa halves, composed where a pick names a downloaded model rather
  /// than a system engine.
  final SherpaVoice _sherpa;

  @override
  bool get hasEngineInstalls => true;

  @override
  Future<NativeVoiceEngines> systemEngines() => probeNativeEngines();

  /// What the synthesiser says it can speak. The recogniser is not asked:
  /// naming its languages means a service bound and, before Android 13, an
  /// ordered broadcast plenty of them never answer — while any phone that can
  /// speak at all answers this off an engine that is being started anyway. A
  /// tag the recogniser cannot do is no dead end either: it descends the ladder
  /// in `VoiceChannel.kt` like the device's own would.
  @override
  Future<List<VoiceLanguage>> systemLanguages() => nativeLanguages(
    timeout: const Duration(seconds: 5),
    failure: "the device would not say what it can speak",
  );

  @override
  Future<VoiceSession> start({
    Hearing? hearing,
    required Speaking speaking,
    int speaker = 0,
    String? language,
  }) async {
    Listener? listener;
    if (hearing case HearOnDevice(:final model) when model.isNative) {
      // Asked for even where nothing is about to listen: the grant is what
      // makes the Talk button work, and a permission sheet on the first press
      // is one nobody expected.
      (await openMicrophone()).dispose();
      listener = NativeSpeechRecognizer(language: language);
    } else if (hearing != null) {
      listener = await _sherpa.sherpaListener(hearing);
    }
    // `speaker` is the sherpa catalog's idea of which voice in a model file to
    // use, and the system synthesiser has no such thing — the voice is the
    // user's, set in the OS. So the settings page draws no picker for it on the
    // native half and nothing is passed on. The language is the picker it
    // draws instead — and is likewise the native synthesiser's: a downloaded
    // model speaks the language it was trained on.
    return composeSession(listener, switch (speaking) {
      SpeakOnDevice(:final model) when model.isNative => Future.value(
        NativeTextToSpeech(language: language),
      ),
      SpeakOnDevice(:final model) => _sherpa.sherpaSpeaker(model, speaker),
      SpeakThrough(:final synthesize) => Future.value(
        RemoteSpeaker(synthesize),
      ),
    });
  }

  @override
  ({String recognition, String speech}) get nativePicks =>
      (recognition: nativeRecognition.id, speech: nativeSpeech.id);
}

/// The platform channel bridging the systems' engines — Android's
/// `TextToSpeech` and `SpeechRecognizer`, iOS's on-device pair — to the
/// [Listener]/[Speaker] strategies. One channel for
/// both, registered on the cached engine against the application context like
/// the other channels — see `VoiceChannel.kt` and `VoiceChannel.swift`.
/// Compiles everywhere; a platform
/// with nothing answering throws, which the strategies surface as
/// [VoiceFailed] the way any other engine fault is surfaced.
const voiceChannel = MethodChannel("agent_chat/voice");

/// What the device's own engines are, by the probe both `VoiceChannel.kt` and
/// `VoiceChannel.swift` answer, or none where nothing is on the other end —
/// one body for both platforms, the strategies being shared for the same
/// reason.
Future<NativeVoiceEngines> probeNativeEngines() async {
  try {
    final answer = await voiceChannel.invokeMapMethod<String, bool>("engines");
    if (answer == null) return NativeVoiceEngines.none;
    return NativeVoiceEngines(
      recognition: answer["recognition"] ?? false,
      speech: answer["speech"] ?? false,
    );
  } catch (_) {
    // Nothing on the other end of the channel has neither engine, which is
    // what the answer would have said.
    return NativeVoiceEngines.none;
  }
}

/// The probe's languages, decoded — the same `[{tag, name}]` maps both native
/// channels answer, so the platforms differ only in how long the answer may
/// take and how a failure is blamed.
Future<List<VoiceLanguage>> nativeLanguages({
  required Duration timeout,
  required String failure,
}) async {
  try {
    // An engine that never finishes answering would leave the picker
    // spinning. Empty is the device's own language and nothing else.
    final answer = await voiceChannel
        .invokeListMethod<Map<Object?, Object?>>("languages")
        .timeout(timeout);
    return [
      for (final language in answer ?? const <Map<Object?, Object?>>[])
        if (language["tag"] case final String tag when tag.isNotEmpty)
          VoiceLanguage(tag: tag, name: language["name"] as String? ?? tag),
    ];
  } catch (e) {
    voiceFailed("$failure: $e");
    return const [];
  }
}

/// Everything the channel says, as a broadcast stream: `setMethodCallHandler`
/// takes one handler, and both strategies listen on the one channel — which
/// is what [PlatformModelChannel] owns. Built on first use.
final Stream<MethodCall> nativeVoiceCalls = () {
  final calls = PlatformModelChannel(voiceChannel).calls;
  // The engine side's chatter on the one subject none of the strategies owns:
  // said through the module's own volume rule, which is debug-only. Listened
  // to once here, so a line is said once however many strategies listen.
  calls
      .where((call) => call.method == "voiceDebug")
      .listen((call) => voiceLog(() => "channel: ${call.arguments}"));
  return calls.where((call) => call.method != "voiceDebug");
}();

/// Listening through the platform's own recognizer behind the shared native
/// contract: Android's `SpeechRecognizer`, iOS's on-device `SFSpeechRecognizer`.
/// No model to load, and no VAD on Android:
/// the OS delivers `onBeginningOfSpeech`, `onRmsChanged` and `onResults`, and
/// this hands all three to [MicrophoneListener], which is where the gate, the
/// level and the event stream are. What is left here is the channel.
class NativeSpeechRecognizer extends MicrophoneListener {
  NativeSpeechRecognizer({this.language}) : super(LoudnessGate()) {
    _calls = nativeVoiceCalls.listen(_onCall);
  }

  /// The BCP-47 tag to hear in, or null for the device's own.
  final String? language;

  late final StreamSubscription<MethodCall> _calls;

  void _onCall(MethodCall call) {
    if (closed) return;
    switch (call.method) {
      case "heard":
        heard((call.arguments as String?) ?? "");
      case "rms":
        measured((call.arguments as num?)?.toDouble() ?? 0);
      case "recognitionError":
        fail((call.arguments as String?) ?? "Recognition failed.");
    }
  }

  @override
  Future<void> setListening(bool on, {bool finish = false}) async {
    if (closed || on == listening) return;
    asked(on);
    try {
      await voiceChannel.invokeMethod<String>("setRecognitionListening", {
        "on": on,
        "finish": finish,
        if (on) "language": language,
      });
    } on PlatformException catch (e) {
      // Only opening it is a failure worth the session: nothing that goes wrong
      // shutting a microphone leaves anyone unable to speak.
      if (on) fail(_message(e, "Recognition failed."));
    } on MissingPluginException {
      if (on) fail("Voice recognition is not available on this platform.");
    }
  }

  @override
  Future<void> dispose() async {
    closed = true;
    await _calls.cancel();
    try {
      await voiceChannel.invokeMethod<String>("stopRecognition");
    } catch (_) {}
    disposeParts();
  }
}

/// Speaking through the platform's synthesiser — Android's `TextToSpeech`,
/// iOS's `AVSpeechSynthesizer` — behind the shared contract. One utterance per
/// [speak] call,
/// queued behind the last; [stop] flushes the queue. Speech is held until the
/// engine says it is ready — a `speak` that lands before init completes returns
/// an error code and no callback, which would count an utterance that never
/// happened and leave a queue that never drains. One utterance failing is not a
/// failed engine: it is dropped, and only repeated failures are reported up.
class NativeTextToSpeech implements Speaker {
  NativeTextToSpeech({this.language}) {
    _calls = nativeVoiceCalls.listen(_onCall);
    unawaited(_init());
  }

  /// The BCP-47 tag to speak in, or null for the device's own.
  final String? language;

  late final StreamSubscription<MethodCall> _calls;
  final _signals = StreamController<SpeechSignal>.broadcast();

  /// Utterances waiting for the engine.
  final _queue = <String>[];
  int _pending = 0;
  int _generation = 0;

  /// One utterance failing is not the engine failing; a run of them is. The
  /// rule is shared with the sherpa speaker, which did not have it.
  final _failures = SpeechFailures();

  /// Whether the engine's init callback has run. Fatal from here on: nothing
  /// that arrives later is believed.
  bool _ready = false;
  bool _failed = false;
  Timer? _watchdog;
  bool _closed = false;

  Future<void> _init() async {
    if (_closed) return;
    // An engine that never answers would hold everything forever; said rather
    // than waited for. Fake clocks in tests only move when pumped.
    _watchdog = Timer(const Duration(seconds: 5), () {
      if (!_ready) _fatal("Speech did not start.");
    });
    try {
      await voiceChannel.invokeMethod<String>("initSpeech", {
        "language": language,
      });
    } on PlatformException catch (e) {
      _fatal(_message(e, "Speech failed."));
    } on MissingPluginException {
      _fatal("Speech synthesis is not available on this platform.");
    }
  }

  void _onCall(MethodCall call) {
    if (_closed || _failed) return;
    switch (call.method) {
      case "speechReady":
        if (_ready) return;
        _ready = true;
        _watchdog?.cancel();
        final queued = List.of(_queue);
        _queue.clear();
        for (final text in queued) {
          unawaited(_dispatch(text));
        }
      case "speechDone":
        // Named by the generation it was queued under, so one arriving after a
        // `stop` is not counted against the batch that replaced it.
        if ((call.arguments as int? ?? 0) != _generation) return;
        _failures.spoke();
        _pending--;
        if (_pending <= 0) {
          _pending = 0;
          _signals.add(const SpeechSilent());
        }
      case "speechUtteranceError":
        if ((call.arguments as int? ?? -1) != _generation) return;
        _utteranceDropped();
      case "speechError":
        _fatal((call.arguments as String?) ?? "Speech failed.");
    }
  }

  /// The engine itself is gone: everything held or playing is dead, and what
  /// arrives later belongs to an engine this side will never see.
  void _fatal(String message) {
    if (_failed || _closed) return;
    _failed = true;
    _watchdog?.cancel();
    _queue.clear();
    _pending = 0;
    _signals.add(SpeechFailed(message));
  }

  /// See [SpeechFailures] for how many of these in a row is an engine rather
  /// than a sentence.
  void _utteranceDropped() {
    if (_pending > 0) _pending--;
    if (_failures.dropped()) {
      _fatal("Speech playback keeps failing.");
    } else if (_pending == 0) {
      _signals.add(const SpeechSilent());
    }
  }

  Future<void> _dispatch(String text) async {
    _pending++;
    try {
      await voiceChannel.invokeMethod<String>("speak", {
        "text": text,
        "generation": _generation,
      });
    } catch (_) {
      // The engine never took the utterance — the same shape a
      // `speechUtteranceError` reports from the other side, so it costs the
      // same budget.
      _utteranceDropped();
    }
  }

  @override
  Stream<SpeechSignal> get signals => _signals.stream;

  @override
  Future<void> speak(String text) async {
    if (_closed || _failed || text.trim().isEmpty) return;
    if (!_ready) {
      _queue.add(text);
      return;
    }
    await _dispatch(text);
  }

  @override
  Future<void> stop() async {
    _generation++;
    _pending = 0;
    _failures.spoke();
    _queue.clear();
    try {
      await voiceChannel.invokeMethod<String>("stopSpeech");
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _watchdog?.cancel();
    _queue.clear();
    await _calls.cancel();
    try {
      await voiceChannel.invokeMethod<String>("disposeSpeech");
    } catch (_) {}
    await _signals.close();
  }
}

String _message(PlatformException e, String fallback) =>
    e.message?.isNotEmpty == true ? e.message! : fallback;
