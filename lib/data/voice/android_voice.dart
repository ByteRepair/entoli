import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:record/record.dart";

import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "voice_strategies.dart";

/// Voice mode on Android, and the whole of it: the device's own `TextToSpeech`
/// and `SpeechRecognizer`, and nothing that has to be downloaded.
///
/// sherpa-onnx is not here, deliberately. It ran on the CPU — onnxruntime's
/// Android build has no GPU execution provider and the only accelerator route
/// it has is deprecated — while the system engines run on whatever the phone
/// has, which on most of them is the NPU. Keeping it would have been 75 MB of
/// native code for a slower answer. It stays on the desktops, which have no
/// system engine to ask. See "The Android system engines" in CLAUDE.md.
///
/// So [start] only ever composes native strategies, and a pick that is not a
/// sentinel is a bug rather than a case: nothing offers one here, since the
/// catalog is not drawn on this platform.
class AndroidVoice extends Voice {
  const AndroidVoice();

  @override
  bool get downloadsModels => false;

  @override
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
  }) async {
    if (!speech.isNative || (recognition != null && !recognition.isNative)) {
      throw StateError("Android runs the system voice engines, not a model.");
    }
    Listener? listener;
    if (recognition != null) {
      // `SpeechRecognizer` opens its own microphone and reports the lack of a
      // grant as an error rather than asking for one, so it is asked for here.
      // `AudioRecorder` is the only thing in the app that can ask, and this is
      // the only thing it is wanted for.
      final recorder = AudioRecorder();
      final allowed = await recorder.hasPermission();
      recorder.dispose();
      if (!allowed) {
        throw StateError("Entoli was not allowed to use the microphone.");
      }
      listener = AndroidSpeechRecognizer();
    }
    return ComposedVoiceSession(listener, AndroidTextToSpeech(speaker: speaker));
  }
}

/// The platform channel bridging the Android `TextToSpeech` and
/// `SpeechRecognizer` to the [Listener]/[Speaker] strategies. One channel for
/// both, registered on the cached engine against the application context like
/// the other channels — see `VoiceChannel.kt`. Compiles everywhere; a platform
/// with nothing answering throws, which the strategies surface as
/// [VoiceFailed] the way any other engine fault is surfaced.
const voiceChannel = MethodChannel("agent_chat/voice");

/// Which of the two system engines this device actually has. Asked once at
/// startup and seeded into a provider, the way the installed models are — asked
/// lazily it is a channel round trip answering "neither" until it returns, and
/// what reads it is a settings page being drawn and a button deciding whether
/// to exist.
///
/// Anything other than an answer is [NativeVoiceEngines.none]: a platform with
/// nothing on the other end of the channel has neither engine, which is the
/// same thing the answer would have said.
Future<NativeVoiceEngines> androidVoiceEngines() async {
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

/// Owns the single [MethodChannel] handler shared by both Android strategies.
/// `setMethodCallHandler` takes one handler, so two strategies each setting it
/// would race — the second overwrites the first. This routes each incoming
/// method to whichever strategy is registered for it, and lets a strategy
/// register/unregister as it is constructed and disposed.
class AndroidVoiceBridge {
  AndroidVoiceBridge._();

  static final AndroidVoiceBridge instance = AndroidVoiceBridge._();

  void Function(String text)? onHeard;
  void Function()? onInterrupted;
  void Function(double level)? onRms;
  void Function(String message)? onRecognitionError;
  void Function(int generation)? onSpeechDone;
  void Function(String message)? onSpeechError;

  void install() {
    voiceChannel.setMethodCallHandler(_onCall);
  }

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case "heard":
        final text = (call.arguments as String?)?.trim() ?? "";
        if (text.isNotEmpty) onHeard?.call(text);
      case "interrupted":
        onInterrupted?.call();
      case "rms":
        final rms = (call.arguments as num?)?.toDouble() ?? 0;
        onRms?.call(rms);
      case "recognitionError":
        onRecognitionError?.call((call.arguments as String?) ?? "Recognition failed.");
      case "speechDone":
        onSpeechDone?.call(call.arguments as int? ?? 0);
      case "speechError":
        onSpeechError?.call((call.arguments as String?) ?? "Speech failed.");
    }
  }
}

/// Listening through Android's `SpeechRecognizer`. No model to load, no VAD:
/// the OS delivers `onBeginningOfSpeech` (→ [VoiceInterrupted]) and
/// `onResults` (→ [VoiceHeard]) directly. [level] is fed from
/// `onRmsChanged`, which the platform emits as an RMS in dB — mapped to 0–1
/// the way the sherpa path maps its own RMS.
class AndroidSpeechRecognizer implements Listener {
  AndroidSpeechRecognizer() {
    final bridge = AndroidVoiceBridge.instance;
    bridge
      ..onHeard = _onHeard
      ..onInterrupted = _onInterrupted
      ..onRms = _onRms
      ..onRecognitionError = _onError
      ..install();
    unawaited(_start());
  }

  final _events = StreamController<VoiceEvent>.broadcast();
  final _levelOf = ValueNotifier(0.0);
  bool _closed = false;

  Future<void> _start() async {
    if (_closed) return;
    try {
      await voiceChannel.invokeMethod<String>("startRecognition");
    } on PlatformException catch (e) {
      _fail(_message(e));
    } on MissingPluginException {
      _fail("Voice recognition is not available on this platform.");
    }
  }

  void _onHeard(String text) {
    if (!_closed) _events.add(VoiceHeard(text));
  }

  void _onInterrupted() {
    if (!_closed) _events.add(const VoiceInterrupted());
  }

  void _onRms(double rms) {
    // `onRmsChanged` reports dB in the range -2..10 roughly; map to 0–1.
    _levelOf.value = ((rms + 2) / 12).clamp(0.0, 1.0);
  }

  void _onError(String message) => _fail(message);

  void _fail(String message) {
    if (!_closed) _events.add(VoiceFailed(message));
  }

  String _message(PlatformException e) =>
      e.message?.isNotEmpty == true ? e.message! : "Recognition failed.";

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  ValueListenable<double> get level => _levelOf;

  @override
  Future<void> setListening(bool on) async {
    if (_closed) return;
    try {
      await voiceChannel.invokeMethod<String>("setRecognitionListening", on);
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    final bridge = AndroidVoiceBridge.instance;
    if (bridge.onHeard == _onHeard) bridge.onHeard = null;
    if (bridge.onInterrupted == _onInterrupted) bridge.onInterrupted = null;
    if (bridge.onRms == _onRms) bridge.onRms = null;
    if (bridge.onRecognitionError == _onError) bridge.onRecognitionError = null;
    try {
      await voiceChannel.invokeMethod<String>("stopRecognition");
    } catch (_) {}
    await _events.close();
    _levelOf.dispose();
  }
}

/// Speaking through Android's `TextToSpeech`. One utterance per [speak] call,
/// queued behind the last; [stop] flushes the queue. The platform signals
/// completion via `onUtteranceProgressListener`, mapped to [SpeechSilent] when
/// the queue has drained and nothing is pending.
class AndroidTextToSpeech implements Speaker {
  AndroidTextToSpeech({this.speaker = 0}) {
    final bridge = AndroidVoiceBridge.instance;
    bridge
      ..onSpeechDone = _onSpeechDone
      ..onSpeechError = _onSpeechError
      ..install();
    unawaited(_init());
  }

  final int speaker;
  final _signals = StreamController<SpeechSignal>.broadcast();
  int _pending = 0;
  int _generation = 0;
  bool _closed = false;

  Future<void> _init() async {
    if (_closed) return;
    try {
      await voiceChannel.invokeMethod<String>("initSpeech");
    } on PlatformException catch (e) {
      _fail(e.message?.isNotEmpty == true ? e.message! : "Speech failed.");
    } on MissingPluginException {
      _fail("Speech synthesis is not available on this platform.");
    }
  }

  void _onSpeechDone(int generation) {
    if (generation != _generation || _closed) return;
    _pending--;
    if (_pending <= 0) {
      _pending = 0;
      _signals.add(const SpeechSilent());
    }
  }

  void _onSpeechError(String message) {
    _pending = 0;
    _fail(message);
  }

  void _fail(String message) {
    if (!_closed) _signals.add(SpeechFailed(message));
  }

  @override
  Stream<SpeechSignal> get signals => _signals.stream;

  /// What the platform has been handed and not reported done. `TextToSpeech`
  /// says nothing about which of queueing, generating and playing it is in, so
  /// this is as fine as the answer gets.
  @override
  bool get speaking => _pending > 0;

  @override
  Future<void> speak(String text) async {
    if (_closed || text.trim().isEmpty) return;
    _pending++;
    try {
      await voiceChannel.invokeMethod<String>("speak", {
        "text": text,
        "speaker": speaker,
        "generation": _generation,
      });
    } catch (e) {
      _pending--;
      _fail("$e");
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _pending = 0;
    try {
      await voiceChannel.invokeMethod<String>("stopSpeech");
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    final bridge = AndroidVoiceBridge.instance;
    if (bridge.onSpeechDone == _onSpeechDone) bridge.onSpeechDone = null;
    if (bridge.onSpeechError == _onSpeechError) bridge.onSpeechError = null;
    try {
      await voiceChannel.invokeMethod<String>("disposeSpeech");
    } catch (_) {}
    await _signals.close();
  }
}