import "dart:async";

import "package:flutter/services.dart";

import "../../domain/loudness.dart";
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
    bool listening = true,
  }) async {
    if (!speech.isNative || (recognition != null && !recognition.isNative)) {
      throw StateError("Android runs the system voice engines, not a model.");
    }
    Listener? listener;
    if (recognition != null) {
      // Asked for even where nothing is about to listen: the grant is what
      // makes the Talk button work, and a permission sheet on the first press
      // is one nobody expected.
      (await openMicrophone()).dispose();
      listener = AndroidSpeechRecognizer(listening: listening);
    }
    // `speaker` is the sherpa catalog's idea of which voice in a model file to
    // use, and the system synthesiser has no such thing — the voice is the
    // user's, set in the OS. So the settings page draws no picker for it here
    // and nothing is passed on.
    return ComposedVoiceSession(listener, AndroidTextToSpeech(),
        listening: listening);
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
/// the OS delivers `onBeginningOfSpeech`, `onRmsChanged` and `onResults`, and
/// this hands all three to [MicrophoneListener], which is where the gate, the
/// level and the event stream are. What is left here is the channel.
class AndroidSpeechRecognizer extends MicrophoneListener {
  AndroidSpeechRecognizer({bool listening = true})
      : super(LoudnessGate()) {
    this.listening = listening;
    _calls = AndroidVoiceBridge.instance.calls.listen(_onCall);
    if (listening) unawaited(_start());
  }

  late final StreamSubscription<MethodCall> _calls;

  Future<void> _start() async {
    if (closed) return;
    try {
      await voiceChannel.invokeMethod<String>("startRecognition");
    } on PlatformException catch (e) {
      fail(_message(e, "Recognition failed."));
    } on MissingPluginException {
      fail("Voice recognition is not available on this platform.");
    }
  }

  void _onCall(MethodCall call) {
    if (closed) return;
    switch (call.method) {
      case "heard":
        heard((call.arguments as String?) ?? "");
      case "interrupted":
        began();
      case "rms":
        measured((call.arguments as num?)?.toDouble() ?? 0);
      case "recognitionError":
        fail((call.arguments as String?) ?? "Recognition failed.");
    }
  }

  @override
  Future<void> setListening(bool on, {bool finish = false}) async {
    if (closed) return;
    asked(on);
    try {
      await voiceChannel.invokeMethod<String>(
          "setRecognitionListening", {"on": on, "finish": finish});
    } catch (_) {}
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
        _failures.spoke();
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
