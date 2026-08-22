import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

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
  Future<NativeVoiceEngines> systemEngines() async {
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
      (await openMicrophone()).dispose();
      listener = AndroidSpeechRecognizer();
    }
    // `speaker` is the sherpa catalog's idea of which voice in a model file to
    // use, and the system synthesiser has no such thing — the voice is the
    // user's, set in the OS. So the settings page draws no picker for it here
    // and nothing is passed on.
    return ComposedVoiceSession(listener, AndroidTextToSpeech());
  }
}

/// The platform channel bridging the Android `TextToSpeech` and
/// `SpeechRecognizer` to the [Listener]/[Speaker] strategies. One channel for
/// both, registered on the cached engine against the application context like
/// the other channels — see `VoiceChannel.kt`. Compiles everywhere; a platform
/// with nothing answering throws, which the strategies surface as
/// [VoiceFailed] the way any other engine fault is surfaced.
const voiceChannel = MethodChannel("agent_chat/voice");

/// Everything Kotlin says, as a stream. `setMethodCallHandler` takes one
/// handler and both strategies listen on the one channel, so the handler is
/// owned here once and what arrives is broadcast; each strategy subscribes and
/// reads the methods that are its own. A subscription is also its own
/// bookkeeping — cancelling on dispose is the whole of it, where a slot per
/// callback needed clearing under an identity check so a successor's
/// registration was not undone by its predecessor.
class AndroidVoiceBridge {
  AndroidVoiceBridge._() {
    voiceChannel.setMethodCallHandler((call) async => _calls.add(call));
  }

  static final AndroidVoiceBridge instance = AndroidVoiceBridge._();

  final _calls = StreamController<MethodCall>.broadcast();

  Stream<MethodCall> get calls => _calls.stream;
}

/// Listening through Android's `SpeechRecognizer`. No model to load, no VAD:
/// the OS delivers `onBeginningOfSpeech` (→ [VoiceInterrupted]) and
/// `onResults` (→ [VoiceHeard]) directly. [level] is fed from
/// `onRmsChanged`, which the platform emits as an RMS in dB — mapped to 0–1
/// the way the sherpa path maps its own RMS.
class AndroidSpeechRecognizer implements Listener {
  AndroidSpeechRecognizer() {
    _calls = AndroidVoiceBridge.instance.calls.listen(_onCall);
    unawaited(_start());
  }

  late final StreamSubscription<MethodCall> _calls;

  /// Single-subscription, the way `SherpaListener`'s is and for its reason: a
  /// failure to start is emitted before anything has subscribed, and a
  /// broadcast controller would drop it on the floor.
  final _events = StreamController<VoiceEvent>();
  final _levelOf = ValueNotifier(0.0);
  bool _closed = false;

  Future<void> _start() async {
    if (_closed) return;
    try {
      await voiceChannel.invokeMethod<String>("startRecognition");
    } on PlatformException catch (e) {
      _fail(_message(e, "Recognition failed."));
    } on MissingPluginException {
      _fail("Voice recognition is not available on this platform.");
    }
  }

  void _onCall(MethodCall call) {
    if (_closed) return;
    switch (call.method) {
      case "heard":
        final text = (call.arguments as String?)?.trim() ?? "";
        if (text.isNotEmpty) _events.add(VoiceHeard(text));
      case "interrupted":
        _events.add(const VoiceInterrupted());
      case "rms":
        // `onRmsChanged` reports dB in the range -2..10 roughly; map to 0–1.
        final rms = (call.arguments as num?)?.toDouble() ?? 0;
        _levelOf.value = ((rms + 2) / 12).clamp(0.0, 1.0);
      case "recognitionError":
        _fail((call.arguments as String?) ?? "Recognition failed.");
    }
  }

  void _fail(String message) {
    if (!_closed) _events.add(VoiceFailed(message));
  }

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
    await _calls.cancel();
    try {
      await voiceChannel.invokeMethod<String>("stopRecognition");
    } catch (_) {}
    // Not awaited: on a single-subscription stream the future from close waits
    // for a listener to take the done event off the buffer, and a recognizer
    // nobody subscribed to — which is exactly what disposing one without
    // starting it means — would hang here forever.
    unawaited(_events.close());
    _levelOf.dispose();
  }
}

/// Speaking through Android's `TextToSpeech`. One utterance per [speak] call,
/// queued behind the last; [stop] flushes the queue. Speech is held until the
/// engine says it is ready — a `speak` that lands before init completes returns
/// an error code and no callback, which would count an utterance that never
/// happened and leave `speaking` true forever. One utterance failing is not a
/// failed engine: it is dropped, and only repeated failures are reported up.
class AndroidTextToSpeech implements Speaker {
  AndroidTextToSpeech() {
    _calls = AndroidVoiceBridge.instance.calls.listen(_onCall);
    unawaited(_init());
  }

  late final StreamSubscription<MethodCall> _calls;
  final _signals = StreamController<SpeechSignal>.broadcast();

  /// Utterances waiting for the engine.
  final _queue = <String>[];
  int _pending = 0;
  int _generation = 0;

  /// Utterances the engine has failed in a row — every success clears it.
  int _failures = 0;

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
      await voiceChannel.invokeMethod<String>("initSpeech");
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
        // barge-in is not counted against the batch that replaced it.
        if ((call.arguments as int? ?? 0) != _generation) return;
        _failures = 0;
        _pending--;
        if (_pending <= 0) {
          _pending = 0;
          _signals.add(const SpeechSilent());
        }
      case "speechUtteranceError":
        // Named by the generation it was queued under, so one arriving after a
        // barge-in is not counted against the batch that replaced it.
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

  /// One dropped utterance is not a broken engine; three with nothing heard
  /// between them are.
  void _utteranceDropped() {
    _failures++;
    if (_pending > 0) _pending--;
    if (_failures >= 3) {
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

  /// What the platform has been handed and not reported done. `TextToSpeech`
  /// says nothing about which of queueing, generating and playing it is in, so
  /// this is as fine as the answer gets.
  @override
  bool get speaking => _pending > 0 || _queue.isNotEmpty;

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
    _failures = 0;
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
